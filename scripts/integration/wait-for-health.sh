#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

require_cmd curl
load_env dev

WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-240}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-3}"

wait_http_ok() {
  local name="$1"
  local url="$2"
  local elapsed=0

  echo "[INFO] Waiting for ${name}: ${url}"

  while (( elapsed < WAIT_TIMEOUT_SECONDS )); do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" || true)"

    if [[ "${code}" =~ ^2[0-9][0-9]$ || "${code}" =~ ^3[0-9][0-9]$ ]]; then
      echo "[PASS] ${name} is healthy (HTTP ${code})."
      return 0
    fi

    sleep "${WAIT_INTERVAL_SECONDS}"
    elapsed=$((elapsed + WAIT_INTERVAL_SECONDS))
  done

  echo "[FAIL] Timeout waiting for ${name}: ${url}" >&2
  return 1
}

wait_http_ok "user-service" "http://localhost:${USER_SERVICE_HOST_PORT}${USER_SERVICE_HEALTH_PATH}"
wait_http_ok "order-service" "http://localhost:${ORDER_SERVICE_HOST_PORT}${ORDER_SERVICE_HEALTH_PATH}"
wait_http_ok "worker-schedule-service" "http://localhost:${WORKER_SCHEDULE_SERVICE_HOST_PORT}${WORKER_SCHEDULE_SERVICE_HEALTH_PATH}"
wait_http_ok "dispatch-service" "http://localhost:${DISPATCH_SERVICE_HOST_PORT}${DISPATCH_SERVICE_HEALTH_PATH}"
wait_http_ok "execution-record-service" "http://localhost:${EXECUTION_RECORD_SERVICE_HOST_PORT}${EXECUTION_RECORD_SERVICE_HEALTH_PATH}"
wait_http_ok "payment-settlement-service" "http://localhost:${PAYMENT_SETTLEMENT_SERVICE_HOST_PORT}${PAYMENT_SETTLEMENT_SERVICE_HEALTH_PATH}"
wait_http_ok "frontend" "http://localhost:${FRONTEND_HOST_PORT}/"
wait_http_ok "nginx" "http://localhost:${NGINX_HOST_PORT}/"
