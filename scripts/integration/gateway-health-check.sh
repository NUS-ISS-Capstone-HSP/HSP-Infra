#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] Missing command: ${cmd}" >&2
    exit 1
  fi
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_cmd curl

if [[ -z "${GATEWAY_HEALTH_BASE_URL:-}" ]]; then
  if [[ -n "${PROD_API_BASE_URL:-}" ]]; then
    GATEWAY_HEALTH_BASE_URL="${PROD_API_BASE_URL}"
  elif [[ -n "${BRUNO_API_BASE_URL:-}" ]]; then
    GATEWAY_HEALTH_BASE_URL="${BRUNO_API_BASE_URL}"
  else
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/env/dev.env"
    GATEWAY_HEALTH_BASE_URL="http://localhost:${NGINX_HOST_PORT}"
  fi
fi

GATEWAY_HEALTH_BASE_URL="${GATEWAY_HEALTH_BASE_URL%/}"

if [[ -z "${GATEWAY_HEALTH_PATH:-}" ]]; then
  if [[ "${GATEWAY_HEALTH_BASE_URL}" == *":8081" ]]; then
    GATEWAY_HEALTH_PATH="/healthz"
  else
    GATEWAY_HEALTH_PATH="/api/healthz"
  fi
fi

GATEWAY_HEALTH_TIMEOUT_SECONDS="${GATEWAY_HEALTH_TIMEOUT_SECONDS:-180}"
GATEWAY_HEALTH_INTERVAL_SECONDS="${GATEWAY_HEALTH_INTERVAL_SECONDS:-5}"
GATEWAY_HEALTH_REPORT_DIR="${GATEWAY_HEALTH_REPORT_DIR:-${ROOT_DIR}/reports/gateway-health}"
GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_BASE_URL}${GATEWAY_HEALTH_PATH}"

mkdir -p "${GATEWAY_HEALTH_REPORT_DIR}"

body_file="${GATEWAY_HEALTH_REPORT_DIR}/response-body.txt"
result_file="${GATEWAY_HEALTH_REPORT_DIR}/result.json"

elapsed=0
attempt=0
last_code="000"
last_time="0"

echo "[INFO] Waiting for API gateway health: ${GATEWAY_HEALTH_URL}"

while (( elapsed < GATEWAY_HEALTH_TIMEOUT_SECONDS )); do
  attempt=$((attempt + 1))

  curl_result="$(curl -sS -o "${body_file}" -w '%{http_code} %{time_total}' "${GATEWAY_HEALTH_URL}" || true)"
  last_code="${curl_result%% *}"
  last_time="${curl_result#* }"

  if [[ "${last_code}" =~ ^2[0-9][0-9]$ || "${last_code}" =~ ^3[0-9][0-9]$ ]]; then
    echo "[PASS] API gateway is healthy (HTTP ${last_code}, ${last_time}s, attempt ${attempt})."
    status="pass"
    break
  fi

  echo "[INFO] Gateway not ready yet (HTTP ${last_code}, attempt ${attempt})."
  sleep "${GATEWAY_HEALTH_INTERVAL_SECONDS}"
  elapsed=$((elapsed + GATEWAY_HEALTH_INTERVAL_SECONDS))
done

status="${status:-fail}"
checked_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
escaped_url="$(printf '%s' "${GATEWAY_HEALTH_URL}" | json_escape)"

cat >"${result_file}" <<JSON
{
  "status": "${status}",
  "url": "${escaped_url}",
  "httpStatus": "${last_code}",
  "responseTimeSeconds": "${last_time}",
  "attempts": ${attempt},
  "checkedAt": "${checked_at}"
}
JSON

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Gateway Health Check"
    echo
    echo "| Item | Value |"
    echo "| --- | --- |"
    echo "| URL | \`${GATEWAY_HEALTH_URL}\` |"
    echo "| Result | ${status} |"
    echo "| HTTP status | ${last_code} |"
    echo "| Response time | ${last_time}s |"
    echo "| Attempts | ${attempt} |"
  } >>"${GITHUB_STEP_SUMMARY}"
fi

if [[ "${status}" != "pass" ]]; then
  echo "[FAIL] API gateway health check failed after ${attempt} attempts: ${GATEWAY_HEALTH_URL}" >&2
  exit 1
fi
