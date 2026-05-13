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

wait_http_ok "api-gateway via nginx" "http://localhost:${NGINX_HOST_PORT}${API_GATEWAY_NGINX_HEALTH_PATH}"
