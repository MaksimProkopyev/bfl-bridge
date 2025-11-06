#!/usr/bin/env bash
set -Eeuo pipefail

trap 'code=$?; echo; echo "❌ Ошибка на шаге: ${BASH_COMMAND} (exit ${code})"; exit ${code}' ERR

# ===== 0) Предусловия =====
need_cmd() { command -v "$1" >/dev/null || { echo "❌ Требуется $1"; exit 1; }; }
need_cmd curl
need_cmd jq

: "${N8N_HOST:?N8N_HOST required}"
: "${WORKFLOW_ID:?WORKFLOW_ID required}"
: "${WEBHOOK_BASE_URL:?WEBHOOK_BASE_URL required}"
if [[ -z "${N8N_API_KEY-}" && -z "${N8N_JWT-}" && -z "${N8N_ADMIN_JWT-}" ]]; then
  echo "❌ Нужен один из: N8N_API_KEY | N8N_JWT | N8N_ADMIN_JWT"; exit 1
fi

print_flag() { # безопасно: без значений
  local n="$1" v="${!1-}"; local s="unset"
  [[ -n "${v}" ]] && s="set(len=${#v})"
  echo "• $n: ${s}"
}
echo "ENV (без значений):"
print_flag N8N_HOST; print_flag WORKFLOW_ID; print_flag WEBHOOK_BASE_URL
print_flag N8N_API_KEY; print_flag N8N_JWT; print_flag N8N_ADMIN_JWT
print_flag OPENAI_API_KEY
print_flag HTTPS_PROXY; print_flag NO_PROXY
echo

# ===== 0.1) Обход прокси для beget/localhost ДО первого curl =====
host_from_webhook="$(printf '%s' "${WEBHOOK_BASE_URL}" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
host_from_api="$(printf '%s' "${N8N_HOST}" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
_np_req_list=(".beget.app" "lunirepoko.beget.app" "localhost" "127.0.0.1" "${host_from_api}" "${host_from_webhook}")
# Текущий список + ведущая запятая для устойчивого поиска по делимитеру
_np_cur=",$(printf '%s' "${NO_PROXY-}")"; _np_cur="${_np_cur%,}"
_np_new=""
for h in "${_np_req_list[@]}"; do
  [[ -z "${h}" ]] && continue
  case ",${_np_cur}," in
    *,"${h}",*) ;;
    *) _np_new="${_np_new:+${_np_new},}${h}"; _np_cur="${_np_cur},${h}";;
  esac
done
if [[ -n "${_np_new}" ]]; then
  export NO_PROXY="${NO_PROXY:+${NO_PROXY},}${_np_new}"
fi
export no_proxy="${NO_PROXY}"
echo "• NO_PROXY expanded (len=${#NO_PROXY})"

curl_noproxy_hosts="${host_from_api}"
if [[ -n "${host_from_webhook}" && "${host_from_webhook}" != "${host_from_api}" ]]; then
  curl_noproxy_hosts+="${curl_noproxy_hosts:+,}${host_from_webhook}"
fi
curl_noproxy_args=()
if [[ -n "${curl_noproxy_hosts//,/}" ]]; then
  curl_noproxy_args=(--noproxy "${curl_noproxy_hosts}")
fi

# Авторизация для n8n REST
auth_args=()
auth_kind=""
if [[ -n "${N8N_API_KEY-}" ]]; then
  auth_args+=( -H "X-N8N-API-KEY: ${N8N_API_KEY}" ); auth_kind="X-N8N-API-KEY"
elif [[ -n "${N8N_JWT-}" ]]; then
  auth_args+=( -H "Authorization: Bearer ${N8N_JWT}" ); auth_kind="JWT"
else
  auth_args+=( -H "Authorization: Bearer ${N8N_ADMIN_JWT}" ); auth_kind="ADMIN_JWT"
fi
echo "REST auth: ${auth_kind}"

curl_with_proxy_retry() {
  local args tmp err status err_msg
  args=("$@")
  tmp="$(mktemp)"
  err="$(mktemp)"

  if curl "${args[@]}" >"${tmp}" 2>"${err}"; then
    status=0
  else
    status=$?
    err_msg="$(<"${err}")"
    if [[ "${err_msg}" == *"CONNECT tunnel failed"* || "${err_msg}" == *"Received HTTP code 403 from proxy after CONNECT"* || "${err_msg}" == *"Proxy CONNECT aborted"* ]]; then
      if curl --noproxy '*' "${args[@]}" >"${tmp}" 2>"${err}"; then
        status=0
      else
        status=$?
      fi
    fi
  fi

  cat "${err}" >&2
  cat "${tmp}"
  rm -f "${tmp}" "${err}"
  return "${status}"
}

api() { # $1=METHOD $2=PATH
  curl_with_proxy_retry \
    -sS -w $'\n%{http_code}' -X "$1" "${N8N_HOST%/}$2" \
    -H 'Content-Type: application/json' "${auth_args[@]}" "${@:3}"
}

# ===== 1) Сетевые проверки =====
echo; echo "→ TLS/HTTP проверка хоста ${N8N_HOST} (bypass proxy)"
curl "${curl_noproxy_args[@]}" -sS -o /dev/null -w "HTTP %{http_code} via %{scheme} TLSv%{ssl_verify_result}\n" "${N8N_HOST%/}/" || true
echo "DNS/TLS ок, если кода ошибки от curl нет."

# Сопоставление хостов
host_from_webhook="$(printf '%s' "${WEBHOOK_BASE_URL}" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
host_from_api="$(printf '%s' "${N8N_HOST}" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
echo "Host(webhook)=${host_from_webhook} | Host(api)=${host_from_api}"
if [[ "${host_from_webhook}" != "${host_from_api}" ]]; then
  echo "⚠️ Несовпадение хостов WEBHOOK_BASE_URL vs N8N_HOST — это допустимо только при корректном проксировании."
fi

# ===== 2) Чтение workflow =====
echo; echo "→ GET /rest/workflows/${WORKFLOW_ID}"
readarray -t resp < <(api GET "/rest/workflows/${WORKFLOW_ID}")
http_code="${resp[-1]}"; unset 'resp[-1]'
body="$(printf "%s\n" "${resp[@]}")"
echo "HTTP ${http_code}"
if [[ "${http_code}" != "200" ]]; then
  echo "RAW:"; echo "${body}" | sed -e 's/[[:space:]]\+$//'
  echo "❌ Не удалось читать воркфлоу — проверь права/ключи/маршрут."
  exit 2
fi
printf "%s" "${body}" > /tmp/wf.json
echo "✓ workflow JSON получен ($(wc -c </tmp/wf.json) bytes)"

# ===== 3) Анализ нод/соединений =====
echo; echo "→ Инвентаризация нод"
jq -r '.nodes[] | "\(.name) |\(.type)"' /tmp/wf.json || { echo "❌ jq parse"; exit 3; }

echo; echo "→ HTTP-ноды и их URL"
jq -r '
  .nodes[]
  | select(.type=="n8n-nodes-base.httpRequest")
  | "\(.name) | " + ( .parameters.url // "(no url) ")
' /tmp/wf.json

echo; echo "→ Проверка URL на A/B (ожидается env-ссылка)"
wantA="{{$env.WEBHOOK_BASE_URL}}/webhook/bfl/leadgen/query-a"
wantB="{{$env.WEBHOOK_BASE_URL}}/webhook/bfl/leadgen/intake-b"
hasA=$(jq -e --arg want "$wantA" '
  [.nodes[] | select(.type=="n8n-nodes-base.httpRequest") | .parameters.url==$want ] | any
' /tmp/wf.json && echo yes || echo no)
hasB=$(jq -e --arg want "$wantB" '
  [.nodes[] | select(.type=="n8n-nodes-base.httpRequest") | .parameters.url==$want ] | any
' /tmp/wf.json && echo yes || echo no)
echo "A url match: ${hasA} | B url match: ${hasB}"

echo; echo "→ Поиск OpenAI Chat и заголовка Authorization"
oa_count=$(jq -r '
  [.nodes[] | select(.type=="n8n-nodes-base.httpRequest" and (.name|test("OpenAI Chat";"i")))] | length
' /tmp/wf.json)
echo "Нод OpenAI Chat: ${oa_count}"
if [[ -n "${OPENAI_API_KEY-}" ]]; then
  oa_auth=$(jq -r '
    [.nodes[]
      | select(.type=="n8n-nodes-base.httpRequest" and (.name|test("OpenAI Chat";"i")))
      | (.parameters.headerParametersUi.parameter // [])
      | map(select(.name=="Authorization"))
      | length
    ] | add // 0
  ' /tmp/wf.json)
  echo "Authorization header в OpenAI Chat: count=${oa_auth} (ожидалось ≥1)"
else
  echo "↷ OPENAI_API_KEY не задан — проверка заголовка пропущена (это ок для диагностики)."
fi

echo; echo "→ Проверка связи Extract Actions → Return"
edge_ok=$(jq -e '
  .connections as $c
  | ($c["Extract Actions"].main[0][]? | select(.node=="Return"))
' /tmp/wf.json >/dev/null 2>&1 && echo yes || echo no)
echo "Связь присутствует: ${edge_ok}"

# ===== 4) Смок внешних вебхуков A/B (без auth) =====
echo; echo "→ Смок-тест A/B без авторизации"
A_URL="${WEBHOOK_BASE_URL%/}/webhook/bfl/leadgen/query-a"
B_URL="${WEBHOOK_BASE_URL%/}/webhook/bfl/leadgen/intake-b"

probe() {
  local url="$1" name="$2"
  local code body resp tmp
  tmp="$(mktemp)"
  resp="$(curl "${curl_noproxy_args[@]}" -sS -o "${tmp}" -w $'\n%{http_code}' -X POST "$url" -H 'content-type: application/json' -d '{}' || true)"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  [[ "${code}" == "${resp}" ]] && body=""
  echo "${name}: HTTP ${code}, body($url) bytes=$(wc -c <"${tmp}")"
  case "$code" in
    200|201|202|204|400|405) echo "✓ ${name} открыт (ожидалось именно это)";;
    401|403) echo "❌ ${name} защищён — вероятно включён Basic/Auth на /webhook/* или конкретном роуте.";;
    *) echo "⚠️ ${name}: нестандартный ответ ${code} — проверь логи n8n/ingress.";;
  esac
  rm -f "${tmp}"
}

probe "${A_URL}" "Webhook A"
probe "${B_URL}" "Webhook B"

# ===== 5) Итоговый отчёт =====
echo; echo "→ Формирую diag_report.json"
jq -n \
  --arg n8n_host "${N8N_HOST}" \
  --arg webhook_base "${WEBHOOK_BASE_URL}" \
  --arg auth "${auth_kind}" \
  --arg hasA "${hasA}" \
  --arg hasB "${hasB}" \
  --arg oa_count "${oa_count}" \
  --arg edge_ok "${edge_ok}" \
  --arg openai_set "$([[ -n "${OPENAI_API_KEY-}" ]] && echo yes || echo no)" \
  --argjson http_nodes "$(jq '[.nodes[] | select(.type=="n8n-nodes-base.httpRequest") | {name, url:(.parameters.url // null), headers: (.parameters.headerParametersUi.parameter // [])}]' /tmp/wf.json)" \
  '
  {
    host: $n8n_host,
    webhook_base: $webhook_base,
    rest_auth: $auth,
    checks: {
      http_nodes: $http_nodes,
      url_match: {A:$hasA, B:$hasB},
      openai_chat_nodes: ($oa_count|tonumber),
      extract_to_return_edge: ($edge_ok=="yes"),
      openai_env_set: ($openai_set=="yes")
    },
    timestamp: (now|todate)
  }' > ./diag_report.json

echo "✅ Диагностика завершена. Итог: ./diag_report.json"
