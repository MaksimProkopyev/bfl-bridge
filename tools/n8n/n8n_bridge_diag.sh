#!/usr/bin/env bash
set -Eeuo pipefail
trap 'c=$?; echo; echo "❌ Ошибка на шаге: ${BASH_COMMAND} (exit ${c})"; exit ${c}' ERR

### 0) Предусловия (значения уже заданы у тебя в окружении; мы их НЕ печатаем)
: "${N8N_HOST:?N8N_HOST required}"
: "${WORKFLOW_ID:?WORKFLOW_ID required}"
: "${WEBHOOK_BASE_URL:?WEBHOOK_BASE_URL required}"
if [[ -z "${N8N_API_KEY-}" && -z "${N8N_JWT-}" && -z "${N8N_ADMIN_JWT-}" ]]; then
  echo "❌ Нужен один из: N8N_API_KEY | N8N_JWT | N8N_ADMIN_JWT"; exit 1
fi
command -v jq >/dev/null || { echo "❌ Требуется jq"; exit 1; }

### 1) Хосты и обход прокси (на время диагностики)
api_host="$(echo "$N8N_HOST" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
wh_host="$(echo "$WEBHOOK_BASE_URL" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}.beget.app,lunirepoko.beget.app,localhost,127.0.0.1,${api_host},${wh_host}"
export no_proxy="$NO_PROXY"

say(){ printf '%b\n' "$*" >&2; }
hr(){ printf '\n%s\n' "------------------------------------------------------------" >&2; }

curl_np(){  # curl с обходом прокси к нужному хосту
  local url="$1"; shift
  local host="$(echo "$url" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
  local needs_url="yes"
  for arg in "$@"; do
    case "$arg" in
      http://*|https://*) needs_url="no"; break ;;
    esac
  done
  if [[ "$needs_url" == "yes" ]]; then
    curl --noproxy "$host" "$@" "$url"
  else
    curl --noproxy "$host" "$@"
  fi
}

auth_args=()
if [[ -n "${N8N_API_KEY-}" ]]; then auth_args+=( -H "X-N8N-API-KEY: ${N8N_API_KEY}" )
elif [[ -n "${N8N_JWT-}" ]]; then auth_args+=( -H "Authorization: Bearer ${N8N_JWT}" )
else auth_args+=( -H "Authorization: Bearer ${N8N_ADMIN_JWT}" ); fi

api(){ curl_np "$N8N_HOST/rest" -sS -f -H 'Content-Type: application/json' "${auth_args[@]}" "$@"; }

### 2) TLS/Reachability (без прокси) + сводка окружения (без секретов)
hr; say "→ Reachability ${N8N_HOST} (без прокси)"
curl_np "${N8N_HOST%/}/" -sS -o /dev/null -w "HTTP %{http_code}, proto=%{scheme}, ip=%{remote_ip}\n" || true
say "ENV-флаги: N8N_HOST=set(len=$((${#N8N_HOST}))), WORKFLOW_ID=set, WEBHOOK_BASE_URL=set, NO_PROXY=len=${#NO_PROXY}"
[[ -n "${HTTPS_PROXY-}" ]] && say "⚠️ HTTPS_PROXY активен (мы его обходим NO_PROXY)"

### 3) REST /workflows/{id}
hr; say "→ REST /rest/workflows/${WORKFLOW_ID}"
set +e
resp="$(api -X GET "$N8N_HOST/rest/workflows/$WORKFLOW_ID" -w $'\n%{http_code}')"
code="${resp##*$'\n'}"; body="${resp%$'\n'*}"; set -e
say "HTTP ${code}"
if [[ "$code" != "200" ]]; then
  say "RAW (укорочено до 600 байт):"; printf '%s' "$body" | head -c 600; echo
  echo "❌ REST недоступен — проверь ключ/хост/прокси"; exit 2
fi
printf '%s' "$body" > /tmp/wf.json
say "id/name/active:"
jq -r '.id, .name, ("active=" + ( .active|tostring ))' /tmp/wf.json | sed 's/^/  /'

### 4) Инвентаризация узлов и статус вебхуков A/B внутри n8n
hr; say "→ Вебхук-узлы в воркфлоу (внутренние настройки)"
jq -r '
  .nodes[]
  | select(.type=="n8n-nodes-base.webhook")
  | [.name, .parameters.path, (.parameters.authentication // "none")] | @tsv
' /tmp/wf.json \
| awk -F'\t' 'BEGIN{printf "  %-26s | %-32s | %s\n","Node","Path","Auth"}{printf "  %-26s | %-32s | %s\n",$1,$2,$3}'

say "→ Ожидаемые пути: bfl/leadgen/query-a и bfl/leadgen/intake-b (Auth должно быть 'none')"
ab_state="$(jq -r '
  [ .nodes[]
    | select(.type=="n8n-nodes-base.webhook" and (.parameters.path=="bfl/leadgen/query-a" or .parameters.path=="bfl/leadgen/intake-b"))
    | (.parameters.path + "=" + ((.parameters.authentication // "none")))
  ] | join(",")
' /tmp/wf.json)"
say "  A/B: ${ab_state}"

### 5) Проверка «моста» (HTTP-вызовы A/B и OpenAI Chat header)
hr; say "→ Проверка нод моста (HTTP → A/B и OpenAI Chat header)"
jq -r '
  .nodes[]
  | if .type=="n8n-nodes-base.httpRequest" and ((.parameters.url // "")|length>0) then
      "  HTTP: " + (.name // "(noname)") + " → " + (.parameters.url)
    elif .type=="n8n-nodes-base.httpRequest" and (.name|test("OpenAI Chat";"i")) then
      "  OpenAI Chat headers: " + (((.parameters.headerParametersUi.parameter // [])|map(.name)|join(",")) // "(none)")
    else empty end
' /tmp/wf.json

### 6) PROD вебхуки A/B (реальная доступность) — без авторизации и без прокси
hr; say "→ PROD вебхуки (без прокси и без auth). Нормальные коды: 2xx/400/405. Не должно быть 401/403."
A_URL="${WEBHOOK_BASE_URL%/}/webhook/bfl/leadgen/query-a"
B_URL="${WEBHOOK_BASE_URL%/}/webhook/bfl/leadgen/intake-b"

probe_wh(){
  local name="$1" url="$2"
  local tmp="$(mktemp)"; local hd="$(mktemp)"
  curl_np "$url" -s -D "$hd" -o "$tmp" -w "%{http_code}" -X POST -H 'content-type: application/json' -d '{}' || true
  local code="$(tail -n1 "$hd" | awk '{print $2}')"
  [[ -z "$code" ]] && code="$(curl_np "$url" -s -o /dev/null -w "%{http_code}" -X POST -H 'content-type: application/json' -d '{}' || true)"
  local wa="$(grep -i '^WWW-Authenticate:' "$hd" || true)"
  local sv="$(grep -i '^Server:' "$hd" || true)"
  local len="$(wc -c <"$tmp" | tr -d ' ')"
  printf '  %-8s → HTTP %s | len=%s | %s | %s\n' "$name" "$code" "$len" "${wa:-no WWW-Authenticate}" "${sv:-no Server}"
  rm -f "$tmp" "$hd"
}
probe_wh "query-a" "$A_URL"
probe_wh "intake-b" "$B_URL"

### 7) Тест против TEST-URL (на всякий случай) — должен быть неактивен без "Listen for test event"
hr; say "→ TEST вебхуки (ожидаемо НЕ работают без Listen):"
TA_URL="${WEBHOOK_BASE_URL%/}/webhook-test/bfl/leadgen/query-a"
TB_URL="${WEBHOOK_BASE_URL%/}/webhook-test/bfl/leadgen/intake-b"
for n in "test-a $TA_URL" "test-b $TB_URL"; do
  set -- $n; nm="$1"; u="$2"
  c=$(curl_np "$u" -s -o /dev/null -w "%{http_code}" -X POST -H 'content-type: application/json' -d '{}' || true)
  printf '  %-8s → HTTP %s\n' "$nm" "$c"
  
done

### 8) Диагноз (машиночитаемый + человекочитаемый)
hr; say "→ Итоговая оценка"
rest_ok="no"; [[ "$code" == "200" ]] && rest_ok="yes"
ab_auth="$(jq -r '
  [ .nodes[]
    | select(.type=="n8n-nodes-base.webhook" and (.parameters.path=="bfl/leadgen/query-a" or .parameters.path=="bfl/leadgen/intake-b"))
    | (.parameters.authentication // "none")
  ] | unique | sort | join(",")
' /tmp/wf.json)"
echo "{}" | jq -c \
  --arg rest "$rest_ok" \
  --arg ab_auth "$ab_auth" \
  --arg a_url "$A_URL" --arg b_url "$B_URL" \
  --arg no_proxy "$NO_PROXY" \
  --arg n8n "$N8N_HOST" \
'{
  rest_ok: $rest=="yes",
  webhook_auth_inside: $ab_auth,   # должно быть "none" (или "none,..." если две ноды)
  prod_urls: {A:$a_url, B:$b_url},
  no_proxy_len: ($no_proxy|length),
  n8n_host: $n8n
}' | tee diag_report.json

say "Правила чтения:"
say "  • rest_ok:true — ключи и коннект к n8n в порядке."
say "  • webhook_auth_inside должно быть 'none'. Если не 'none' → в самих узлах включена авторизация."
say "  • Если в шаге 6 видим 401/403 и заголовок 'WWW-Authenticate: Basic' → это внешний Basic/Auth на /webhook/* (прокси/хостинг)."
say "  • Коды 400/405 на шаге 6 — это норма для пустого тела. Главное — не 401/403."
say "  • TEST-URL (/webhook-test/...) без 'Listen' почти всегда неработоспособен — используем PROD-URL."
hr; say "✅ Диагностика завершена. Сводка: ./diag_report.json"
