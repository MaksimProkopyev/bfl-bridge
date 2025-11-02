#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env.local"

if [[ -f "${ENV_FILE}" ]]; then
  while IFS='=' read -r key value; do
    if [[ -z "${key}" ]] || [[ "${key}" == \#* ]]; then
      continue
    fi
    value="${value%$'\r'}"
    export "${key}"="${value}"
  done < "${ENV_FILE}"
fi

AUTH_HEADER=""
if [[ -n "${N8N_ADMIN_JWT:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer ${N8N_ADMIN_JWT}"
elif [[ -n "${N8N_JWT:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer ${N8N_JWT}"
elif [[ -n "${N8N_API_KEY:-}" ]]; then
  AUTH_HEADER="X-N8N-API-KEY: ${N8N_API_KEY}"
fi

AUTH_ARGS=()
if [[ -n "${AUTH_HEADER}" ]]; then
  AUTH_ARGS=(-H "${AUTH_HEADER}")
fi

missing=()
for var in N8N_HOST WORKFLOW_ID WEBHOOK_BASE_URL; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("${var}")
  fi
done

if [[ -z "${AUTH_HEADER}" ]]; then
  missing+=("N8N_JWT|N8N_ADMIN_JWT|N8N_API_KEY")
fi

if (( ${#missing[@]} > 0 )); then
  echo "test:e2e: {\"ok\":false,\"error\":\"missing env: ${missing[*]}\"}" >&2
  exit 1
fi

N8N_BASE="${N8N_HOST%/}"
payload="$(python - <<'PY'
import json
import os
payload = {
    "workflowId": os.environ["WORKFLOW_ID"],
    "mode": "manual",
    "startNode": "Extract Actions",
    "data": {
        "runData": {
            "Extract Actions": [
                {
                    "json": {
                        "actions": {
                            "to_a": ["https://example.com/demo"],
                            "to_b": [{"id": "candidate-1"}]
                        }
                    }
                }
            ]
        }
    }
}
print(json.dumps(payload))
PY
)"

response="$(curl -sS -X POST "${N8N_BASE}/rest/workflows/run" \
  -H "Content-Type: application/json" \
  "${AUTH_ARGS[@]}" \
  --data "${payload}")"

parsed="$(python - "$response" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception as exc:
    print(json.dumps({"ok": False, "error": f"invalid-json: {exc}"}))
    sys.exit(1)

execution_id = data.get("executionId")
if not execution_id:
    print(json.dumps({"ok": False, "error": "missing executionId"}))
    sys.exit(1)
print(json.dumps({"ok": True, "executionId": execution_id}))
PY
)"

execution_id="$(python - <<'PY'
import json
import sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
print(data.get("executionId", ""))
PY <<<'${parsed}')"

if [[ -z "${execution_id}" ]]; then
  echo "test:e2e: ${parsed}"
  exit 1
fi

wait_attempts=20
sleep_interval=3
status_json=""
for ((i=0; i<wait_attempts; i++)); do
  status_json="$(curl -sS "${AUTH_ARGS[@]}" "${N8N_BASE}/rest/executions/${execution_id}")"
  finished="$(python - <<'PY'
import json
import sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print("false")
    sys.exit(0)
print("true" if data.get("data", {}).get("finished") else "false")
PY <<<'${status_json}')"
  if [[ "${finished}" == "true" ]]; then
    break
  fi
  sleep "${sleep_interval}"
done

result="$(python - <<'PY'
import json
import sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception as exc:
    print(json.dumps({"ok": False, "error": f"status-json: {exc}"}))
    sys.exit(0)
run_data = data.get("data", {}).get("data", {}).get("resultData", {}).get("runData", {})
counts = {"to_a": 0, "to_b": 0}
errors = []


def accumulate(node_key, count_key):
    node_runs = run_data.get(node_key, []) or []
    total = 0
    for entry in node_runs:
        payload = entry.get("json", {}) if isinstance(entry, dict) else {}
        status = payload.get("statusCode")
        if status is None:
            errors.append(f"{node_key}:missing_status")
        elif not (200 <= int(status) < 300):
            errors.append(f"{node_key}:status_{status}")
        body = payload.get("body")
        if isinstance(body, list):
            total += len(body)
        elif body is not None:
            total += 1
    counts[count_key] = total


accumulate("leadgen_a_http", "to_a")
accumulate("leadgen_b_http", "to_b")

if errors:
    print(json.dumps({"ok": False, "counts": counts, "errors": errors}))
else:
    print(json.dumps({"ok": True, "counts": counts}))
PY <<<'${status_json}')"

echo "test:e2e: ${result}"
