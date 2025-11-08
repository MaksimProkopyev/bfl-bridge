#!/usr/bin/env bash
set -Eeuo pipefail
command -v bash curl jq git npm >/dev/null
# отключаем прокси и чиним DNS через DoH (идемпотентно)
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY || true
export NO_PROXY=".beget.app,lunirepoko.beget.app,localhost,127.0.0.1"; export no_proxy="$NO_PROXY"
if ! getent hosts lunirepoko.beget.app >/dev/null 2>&1; then
  RES_IP="$(curl -sS -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=lunirepoko.beget.app&type=A' | jq -r '.Answer[0].data' 2>/dev/null || true)"
  [[ "$RES_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || RES_IP="$(curl -sS -H 'accept: application/dns-json' 'https://dns.google/resolve?name=lunirepoko.beget.app&type=A' | jq -r '.Answer[0].data' 2>/dev/null || true)"
  if [[ "$RES_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! grep -q "lunirepoko.beget.app" /etc/hosts; then
    if [[ -w /etc/hosts ]]; then
      printf '%s lunirepoko.beget.app\n' "$RES_IP" >> /etc/hosts
    elif command -v sudo >/dev/null 2>&1; then
      printf '%s lunirepoko.beget.app\n' "$RES_IP" | sudo tee -a /etc/hosts >/dev/null
    else
      echo "WARN: cannot update /etc/hosts (no write permission)" >&2
    fi
  fi
fi

# синк репо и helper
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin https://github.com/MaksimProkopyev/bfl-bridge.git
fi
if ! git fetch origin; then
  echo "GIT_FETCH_ERROR: unable to reach origin" >&2
  exit 10
fi
git checkout main
git reset --hard origin/main
test -f tools/n8n/bridge_diag_fix.sh || { echo "MISSING: tools/n8n/bridge_diag_fix.sh"; exit 1; }
chmod +x tools/n8n/bridge_diag_fix.sh

# ENV (секреты не печатать)
export N8N_HOST="https://lunirepoko.beget.app"
export WORKFLOW_ID="xn9lyjuCxY2Dhyc9"
export WEBHOOK_BASE_URL="$N8N_HOST"
[[ -n "${N8N_API_KEY-}${N8N_JWT-}${N8N_ADMIN_JWT-}" ]] || { echo "MISSING_AUTH: set one of N8N_API_KEY|N8N_JWT|N8N_ADMIN_JWT (do not print it)"; exit 2; }

# патч/активация воркфлоу
npm run -s patch:bridge || ./tools/n8n/bridge_diag_fix.sh

# REST + смоки + отчёт
declare -a AUTH_ARGS=()
if [[ -n "${N8N_API_KEY-}" ]]; then AUTH_ARGS=(-H "X-N8N-API-KEY: ${N8N_API_KEY}")
elif [[ -n "${N8N_JWT-}" ]]; then AUTH_ARGS=(-H "Authorization: Bearer ${N8N_JWT}")
else AUTH_ARGS=(-H "Authorization: Bearer ${N8N_ADMIN_JWT}"); fi

WF_TMP="$(mktemp)"
set +e
REST_CODE="$(curl -sS -o "$WF_TMP" -w "%{http_code}" "${AUTH_ARGS[@]}" "$N8N_HOST/rest/workflows/$WORKFLOW_ID")"; RC=$?
set -e
(( RC==0 )) || { echo "CURL_ERROR: rc=$RC"; cat "$WF_TMP"; exit 3; }
[[ "$REST_CODE" == "200" ]] || { echo "RAW_RESPONSE_CODE:$REST_CODE"; cat "$WF_TMP"; exit 4; }
WF_JSON="$(jq -c '.data // .' "$WF_TMP")"
WF_ID="$(jq -r '.id'<<<"$WF_JSON")"; WF_NAME="$(jq -r '.name'<<<"$WF_JSON")"
WF_ACTIVE="$(jq -r '.active // false'<<<"$WF_JSON")"

probe(){ local p="$1" H="$(mktemp)"; curl -s -D "$H" -o /dev/null -X POST -H 'content-type: application/json' --data '{}' "$N8N_HOST/webhook/bfl/leadgen/$p" >/dev/null; local code; code="$(awk 'BEGIN{c=""} /^HTTP/{c=$2} END{print c}' "$H")"; local wa; wa="$(awk 'BEGIN{FS=": *"} tolower($1)=="www-authenticate"{print $2}' "$H"|tr -d '\r'|head -n1)"; rm -f "$H"; [[ -z "$wa" ]]&&wa="none"; printf "%s|%s\n" "$code" "$wa"; }
read -r CODE_A WA_A <<<"$(probe query-a | awk -F'|' '{print $1, $2}')"
read -r CODE_B WA_B <<<"$(probe intake-b | awk -F'|' '{print $1, $2}')"

STATE_TABLE="$(
jq -r '.nodes[] | select(.type|test("webhook";"i")) | [.name, (.parameters.path // "—"), (.parameters.authentication // "—")] | @tsv' <<<"$WF_JSON" \
| awk -F'\t' '{printf "  %s | %s | %s\n", $1, $2, $3}'
)"
URLS_AB="$(
jq -r '.nodes[] | select(.type|test("httpRequest";"i")) | select((.parameters.url // "")|test("/webhook/bfl/leadgen/(query-a|intake-b)")) | .parameters.url'<<<"$WF_JSON" \
| awk '{printf "  %s\n", $0}'
)"; [[ -z "$URLS_AB" ]] && URLS_AB="  (not found)"
OPENAI_AUTH_STATE="$(
jq -r '.nodes[] | select(.type|test("httpRequest";"i"))
| select((.name // "")|test("OpenAI Chat";"i") or (.parameters.url // "")|test("api.openai.com/.*/chat"))
| (((.parameters.options // {} ) as $o
    | [$o.headers, $o.headerParametersUi, .parameters.headerParametersUi]
    | map(try .parameters // .) | flatten
    | map(select(.name? != null) | "\(.name)=\(.value // .value2 // .value3 // "")")) // []) as $h
| if ($h | map(test("^Authorization=.*OPENAI_API_KEY")) | any) then "present"
  elif ($h | map(test("^Authorization=.*")) | any) then "missing" else "absent" end'<<<"$WF_JSON" | head -n1
)"; [[ -z "$OPENAI_AUTH_STATE" ]] && OPENAI_AUTH_STATE="absent"
EXTRACT_TO_RETURN="$(
jq -r '
  def has($n): (.nodes[]?.name // "" | contains($n));
  def edge($f;$t):
    (.connections // {}) | to_entries[] | select(.key==$f) | .value.main[]? | .[]? | select(.node==$t) | any;
  if (has("Extract Actions") and has("Return")) and edge("Extract Actions";"Return") then "present" else "missing" end
'<<<"$WF_JSON")"

NOTES="OK"
if [[ "$CODE_A" =~ ^40(1|3)$ ]] || [[ "$CODE_B" =~ ^40(1|3)$ ]] || [[ "$WA_A" != "none" ]] || [[ "$WA_B" != "none" ]]; then
  NOTES="External layer (proxy/hosting) enforces auth — webhooks auth=None inside n8n"
fi

echo
echo "REST: $REST_CODE -> id=$WF_ID name=$WF_NAME"
echo "WEBHOOKS:"
echo "  A $CODE_A (WWW-Authenticate: $WA_A)"
echo "  B $CODE_B (WWW-Authenticate: $WA_B)"
echo "STATE (after patch):"
echo "  Node | Path | Auth"
printf "%s\n" "${STATE_TABLE:-  (no webhook nodes found)}"
echo "INVARIANTS:"
echo "  URLs:"; printf "%s\n" "$URLS_AB"
echo "  OpenAI Chat Authorization header: $OPENAI_AUTH_STATE"
echo "  Extract Actions → Return: $EXTRACT_TO_RETURN"
echo "  Workflow Active: $WF_ACTIVE"
echo "NOTES:"; echo "  $NOTES"
