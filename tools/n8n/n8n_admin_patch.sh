#!/usr/bin/env bash
set -Eeuo pipefail

trap 'c=$?; echo "❌ Ошибка: ${BASH_COMMAND} (exit ${c})"; exit ${c}' ERR

# ===== 0) Предусловия =====
: "${N8N_HOST:?N8N_HOST required}"
: "${WORKFLOW_ID:?WORKFLOW_ID required}"
: "${WEBHOOK_BASE_URL:?WEBHOOK_BASE_URL required}"
if [[ -z "${N8N_API_KEY-}" && -z "${N8N_JWT-}" && -z "${N8N_ADMIN_JWT-}" ]]; then
  echo "❌ нужен один из N8N_API_KEY|N8N_JWT|N8N_ADMIN_JWT"; exit 1
fi
command -v jq >/dev/null || { echo "❌ требуется jq"; exit 1; }

# ===== 0.1) Локальный обход прокси для beget/localhost =====
export NO_PROXY=".beget.app,lunirepoko.beget.app,localhost,127.0.0.1"
export no_proxy="${NO_PROXY}"
api_host="$(echo "${N8N_HOST}" | sed -E 's#^https?://([^/]+)/?.*#\1#')"

# ===== 0.2) Авторизация =====
auth=()
if [[ -n "${N8N_API_KEY-}" ]]; then
  auth+=(-H "X-N8N-API-KEY: ${N8N_API_KEY}")
elif [[ -n "${N8N_JWT-}" ]]; then
  auth+=(-H "Authorization: Bearer ${N8N_JWT}")
else
  auth+=(-H "Authorization: Bearer ${N8N_ADMIN_JWT}")
fi
api() { curl --noproxy "${api_host}" -sS -f -H 'Content-Type: application/json' "${auth[@]}" "$@"; }

# ===== 1) Получение списков =====
echo "→ Читаю список воркфлоу"
api -X GET "${N8N_HOST%/}/rest/workflows" > /tmp/_n8n_workflows.json

jq -r '
  ( .data // . )
  | map(select(.nodes | any(.type=="n8n-nodes-base.webhook" and (.parameters.path=="bfl/leadgen/query-a" or .parameters.path=="bfl/leadgen/intake-b"))))
  | .[].id
' /tmp/_n8n_workflows.json | sort -u > /tmp/_n8n_ab_ids.txt

echo "Webhook A/B в воркфлоу: $(wc -l < /tmp/_n8n_ab_ids.txt)"

# ===== 2) Обновление воркфлоу с вебхуками A/B =====
patch_and_write() {
  local id="$1"
  api -X GET "${N8N_HOST%/}/rest/workflows/${id}" > "/tmp/_n8n_wf.${id}.json"

  jq '
    .nodes |= map(
      if .type=="n8n-nodes-base.webhook"
         and (.parameters.path=="bfl/leadgen/query-a" or .parameters.path=="bfl/leadgen/intake-b") then
        .parameters.authentication = "none"
        | .credentials = ((.credentials // {}) | del(.httpBasicAuth) | del(.httpHeaderAuth) | del(.httpDigestAuth))
      else
        .
      end
    )
    | .active = true
  ' "/tmp/_n8n_wf.${id}.json" > "/tmp/_n8n_wf.${id}.patched.json"

  if diff -q "/tmp/_n8n_wf.${id}.json" "/tmp/_n8n_wf.${id}.patched.json" >/dev/null; then
    echo "✓ wf ${id}: изменений нет"
  else
    echo "→ Обновляю wf ${id}"
    api -X PATCH "${N8N_HOST%/}/rest/workflows/${id}" --data-binary @"/tmp/_n8n_wf.${id}.patched.json" >/dev/null
    echo "✓ wf ${id}: обновлён"
  fi
}

while read -r wid; do
  [[ -n "${wid}" ]] && patch_and_write "${wid}"
done < /tmp/_n8n_ab_ids.txt || true

# ===== 3) Патч основного моста =====
api -X GET "${N8N_HOST%/}/rest/workflows/${WORKFLOW_ID}" > /tmp/_n8n_bridge.json
jq '
  .nodes |= map(
    if .type=="n8n-nodes-base.httpRequest" and (.parameters.url? // "" | test("/webhook/bfl/leadgen/query-a$")) then
      .parameters.url = "{{$env.WEBHOOK_BASE_URL}}/webhook/bfl/leadgen/query-a"
    elif .type=="n8n-nodes-base.httpRequest" and (.parameters.url? // "" | test("/webhook/bfl/leadgen/intake-b$")) then
      .parameters.url = "{{$env.WEBHOOK_BASE_URL}}/webhook/bfl/leadgen/intake-b"
    elif .type=="n8n-nodes-base.httpRequest" and (.name|test("OpenAI Chat";"i")) then
      .parameters.headerParametersUi.parameter = (
        ((.parameters.headerParametersUi.parameter // []) | map(select(.name!="Authorization")))
        + [{"name":"Authorization","value":"Bearer {{$env.OPENAI_API_KEY}}"}]
      )
    else
      .
    end
  )
' /tmp/_n8n_bridge.json > /tmp/_n8n_bridge.patched.json

if diff -q /tmp/_n8n_bridge.json /tmp/_n8n_bridge.patched.json >/dev/null; then
  echo "✓ bridge: без изменений"
else
  echo "→ Обновляю bridge ${WORKFLOW_ID}"
  api -X PATCH "${N8N_HOST%/}/rest/workflows/${WORKFLOW_ID}" --data-binary @/tmp/_n8n_bridge.patched.json >/dev/null
  echo "✓ bridge обновлён"
fi

# ===== 4) Быстрая проверка =====
echo "→ Проверка REST /workflows/{id}"
api -X GET "${N8N_HOST%/}/rest/workflows/${WORKFLOW_ID}" | jq '.id,.name' | sed 's/^/  /'

echo "→ Смок A/B (ожидаем НЕ 401/403; 2xx/400/405 — норм)"
wh_host="$(echo "${WEBHOOK_BASE_URL}" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
for p in query-a intake-b; do
  code=$(curl --noproxy "${wh_host}" -s -o /dev/null -w "%{http_code}" -X POST "${WEBHOOK_BASE_URL%/}/webhook/bfl/leadgen/${p}" -H 'content-type: application/json' -d '{}' || true)
  echo "  ${p}: HTTP ${code}"
done

echo "✅ Внутри n8n: вебхуки A/B = authentication:none; воркфлоу активированы; мост обновлён."
echo "ℹ️ Если A/B всё ещё дают 401/403 — это ВНЕШНЯЯ защита на прокси/хостинге. Снимите Basic/Auth на маршруте /webhook/* и повторите смок."
