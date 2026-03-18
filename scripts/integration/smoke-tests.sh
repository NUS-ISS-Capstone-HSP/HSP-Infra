#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

require_cmd curl
load_env dev

assert_http_ok() {
  local name="$1"
  local url="$2"
  local code

  code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" || true)"
  if [[ "${code}" =~ ^2[0-9][0-9]$ || "${code}" =~ ^3[0-9][0-9]$ ]]; then
    echo "[PASS] ${name}: ${url} (HTTP ${code})"
    return 0
  fi

  echo "[FAIL] ${name}: ${url} (HTTP ${code})" >&2
  return 1
}

"${SCRIPT_DIR}/wait-for-health.sh"

assert_http_ok "Users service direct" "http://localhost:${USER_SERVICE_HOST_PORT}${USER_SERVICE_HEALTH_PATH}"
assert_http_ok "Orders service direct" "http://localhost:${ORDER_SERVICE_HOST_PORT}${ORDER_SERVICE_HEALTH_PATH}"
assert_http_ok "Frontend via gateway" "http://localhost:${NGINX_HOST_PORT}${SMOKE_FRONTEND_PATH}"
assert_http_ok "Users API via gateway" "http://localhost:${NGINX_HOST_PORT}${SMOKE_USERS_PATH}"
assert_http_ok "Orders API via gateway" "http://localhost:${NGINX_HOST_PORT}${SMOKE_ORDERS_PATH}"
