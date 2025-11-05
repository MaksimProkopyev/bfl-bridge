#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env.local"

is_truthy() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

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

curl_env_cmd=(env)
proxy_env_vars=(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)
if is_truthy "${N8N_CURL_DISABLE_PROXY:-}"; then
  for var in "${proxy_env_vars[@]}" NO_PROXY no_proxy; do
    curl_env_cmd+=(-u "${var}")
  done
else
  if [[ -n "${N8N_CURL_PROXY:-}" ]]; then
    for var in "${proxy_env_vars[@]}"; do
      curl_env_cmd+=("${var}=${N8N_CURL_PROXY}")
    done
  fi
fi

if [[ -n "${N8N_CURL_NO_PROXY:-}" ]]; then
  curl_env_cmd+=("NO_PROXY=${N8N_CURL_NO_PROXY}" "no_proxy=${N8N_CURL_NO_PROXY}")
fi

if (( ${#curl_env_cmd[@]} == 1 )); then
  curl_env_cmd=()
fi

CURL_EXTRA_ARGS=()
if [[ -n "${N8N_CURL_EXTRA_ARGS:-}" ]]; then
  while IFS= read -r line; do
    CURL_EXTRA_ARGS+=("${line}")
  done < <(
    python - <<'PY'
import json
import os
import sys
raw = os.environ.get('N8N_CURL_EXTRA_ARGS', '')
try:
    value = json.loads(raw)
except Exception as exc:  # noqa: BLE001
    print(f'invalid-json: {exc}', file=sys.stderr)
    sys.exit(1)
if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
    print('N8N_CURL_EXTRA_ARGS must be a JSON array of strings', file=sys.stderr)
    sys.exit(1)
for item in value:
    print(item)
PY
  )
fi

run_curl() {
  local args=()
  args+=(-sS)
  if (( ${#CURL_EXTRA_ARGS[@]} > 0 )); then
    args+=("${CURL_EXTRA_ARGS[@]}")
  fi
  args+=("$@")
  if (( ${#curl_env_cmd[@]} > 0 )); then
    "${curl_env_cmd[@]}" curl "${args[@]}"
  else
    curl "${args[@]}"
  fi
}

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

response="$(run_curl -X POST "${N8N_BASE}/rest/workflows/run" \
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
finished="false"
for ((i=0; i<wait_attempts; i++)); do
  status_json="$(run_curl "${AUTH_ARGS[@]}" "${N8N_BASE}/rest/executions/${execution_id}")"
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

if [[ -z "${status_json}" ]]; then
  echo "test:e2e: {\"ok\":false,\"error\":\"execution status unavailable\"}"
  exit 1
fi

if [[ "${finished}" != "true" ]]; then
  echo "test:e2e: {\"ok\":false,\"error\":\"execution did not finish in time\"}"
  exit 1
fi

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


def normalise_body(value):
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        if not value:
            return None
        try:
            return json.loads(value)
        except Exception:  # noqa: BLE001
            return value
    return value


def accumulate(node_keys, count_key, payload_key):
    total = 0
    for node_key in node_keys:
        node_runs = run_data.get(node_key, []) or []
        for entry in node_runs:
            payload = entry.get("json", {}) if isinstance(entry, dict) else {}
            status = payload.get("statusCode")
            if status is None:
                errors.append(f"{node_key}:missing_status")
            elif not (200 <= int(status) < 300):
                errors.append(f"{node_key}:status_{status}")

            candidates = []
            if isinstance(payload, dict):
                request = payload.get("request")
                if isinstance(request, dict):
                    candidates.append(("request", request.get("body")))
            if isinstance(entry, dict):
                data_body = None
                if isinstance(entry.get("data"), dict):
                    data_body = entry["data"].get("body")
                    candidates.append(("data", data_body))
                candidates.append(("entry", entry.get("body")))
            if isinstance(payload, dict):
                candidates.append(("payload", payload.get("body")))

            counted = False
            seen_usable_zero = False
            for _source, candidate in candidates:
                body = normalise_body(candidate)
                if body is None:
                    continue

                def summarise_payload(payload_value):
                    if isinstance(payload_value, list):
                        return len(payload_value), True
                    if isinstance(payload_value, dict):
                        if payload_value:
                            return 1, True
                        return 0, False
                    if isinstance(payload_value, str):
                        payload_value = payload_value.strip()
                        if payload_value:
                            return 1, True
                        return 0, False
                    if payload_value not in (None, "", []):
                        return 1, True
                    return 0, False

                def summarise(value):
                    if isinstance(value, list):
                        return len(value), True
                    if isinstance(value, dict):
                        def inspect(container):
                            candidate_keys = [
                                key for key in (count_key, payload_key) if key
                            ]
                            for candidate_key in candidate_keys:
                                if candidate_key in container:
                                    return summarise_payload(container.get(candidate_key))

                            other_counter_keys = [
                                key for key in ("to_a", "to_b") if key and key != count_key
                            ]
                            if any(key in container for key in other_counter_keys):
                                return 0, True

                            return None

                        inspected = inspect(value)
                        if inspected is not None:
                            return inspected

                        actions = value.get("actions")
                        if isinstance(actions, dict):
                            inspected = inspect(actions)
                            if inspected is not None:
                                return inspected

                        if value:
                            other_counter_keys = [
                                key for key in ("to_a", "to_b") if key and key != count_key
                            ]
                            if any(key in value for key in other_counter_keys):
                                return 0, True
                            if isinstance(actions, dict) and any(
                                key in actions for key in other_counter_keys
                            ):
                                return 0, True
                            return 1, True
                        return 0, False
                    if isinstance(value, str):
                        value = value.strip()
                        if value:
                            return 1, True
                        return 0, False
                    if value not in (None, "", []):
                        return 1, True
                    return 0, False

                count, usable = summarise(body)
                if not usable:
                    continue
                if count > 0:
                    total += count
                    counted = True
                    break
                seen_usable_zero = True
            if not counted and seen_usable_zero:
                counted = True
            if not counted:
                errors.append(f"{node_key}:missing_body")
    counts[count_key] = total


accumulate(["leadgen_a_http", "HTTP A", "HTTP A Request"], "to_a", "new_urls")
accumulate(["leadgen_b_http", "HTTP B", "HTTP B Request"], "to_b", "candidates")

if errors:
    print(json.dumps({"ok": False, "counts": counts, "errors": errors}))
else:
    print(json.dumps({"ok": True, "counts": counts}))
PY <<<'${status_json}')"

echo "test:e2e: ${result}"
