#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env.local"

log() {
  printf 'bridge_diag_fix: %s\n' "$*" >&2
}

is_truthy() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -f "${ENV_FILE}" ]]; then
  while IFS='=' read -r key value; do
    if [[ -z "${key}" || "${key}" == \#* ]]; then
      continue
    fi
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "${value}" == \"* && "${value}" == *\" ]]; then
      value="${value:1:-1}"
    elif [[ "${value}" == \'* && "${value}" == *\' ]]; then
      value="${value:1:-1}"
    fi
    export "${key}"="${value}"
  done < "${ENV_FILE}"
fi

DEFAULT_NO_PROXY=".beget.app,lunirepoko.beget.app,localhost,127.0.0.1"
if [[ -z "${NO_PROXY:-}" ]]; then
  export NO_PROXY="${DEFAULT_NO_PROXY}"
fi
if [[ -z "${no_proxy:-}" ]]; then
  export no_proxy="${NO_PROXY}"
fi
if [[ -z "${N8N_CURL_NO_PROXY:-}" ]]; then
  export N8N_CURL_NO_PROXY="${NO_PROXY}"
fi
if [[ -z "${N8N_CURL_DISABLE_PROXY:-}" ]]; then
  export N8N_CURL_DISABLE_PROXY=1
fi

missing=()
for var in N8N_HOST WORKFLOW_ID WEBHOOK_BASE_URL; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("${var}")
  fi
done

if [[ -z "${N8N_API_KEY:-}" && -z "${N8N_JWT:-}" && -z "${N8N_ADMIN_JWT:-}" ]]; then
  missing+=("N8N_API_KEY|N8N_JWT|N8N_ADMIN_JWT")
fi

if (( ${#missing[@]} > 0 )); then
  printf 'bridge_diag_fix: missing env: %s\n' "${missing[*]}" >&2
  exit 1
fi

log "patching workflow via tools/n8n/patch-bridge.mjs"
node "${ROOT_DIR}/tools/n8n/patch-bridge.mjs"

if [[ -x "${ROOT_DIR}/tools/n8n/test-e2e.sh" ]]; then
  if is_truthy "${BRIDGE_SKIP_E2E:-}"; then
    log "skipping E2E diagnostics (BRIDGE_SKIP_E2E)"
  else
    log "running tools/n8n/test-e2e.sh"
    "${ROOT_DIR}/tools/n8n/test-e2e.sh"
  fi
else
  log "tools/n8n/test-e2e.sh not found; skipping diagnostics"
fi

log "complete"
