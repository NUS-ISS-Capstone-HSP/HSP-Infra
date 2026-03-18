#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

require_cmd curl
load_env dev

ORDER_FLOW_ENABLED="${ORDER_FLOW_ENABLED:-true}"
if [[ "${ORDER_FLOW_ENABLED}" != "true" ]]; then
  echo "[INFO] ORDER_FLOW_ENABLED=false, skipping order flow test."
  exit 0
fi

post_json_expect_success() {
  local name="$1"
  local url="$2"
  local payload="$3"

  local response_file
  response_file="$(mktemp)"

  local code
  code="$(curl -sS -o "${response_file}" -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -d "${payload}" \
    "${url}" || true)"

  if [[ "${code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "[PASS] ${name} succeeded (HTTP ${code})"
    rm -f "${response_file}"
    return 0
  fi

  echo "[FAIL] ${name} failed (HTTP ${code})" >&2
  echo "[DEBUG] ${name} response body:" >&2
  cat "${response_file}" >&2
  rm -f "${response_file}"
  return 1
}

"${SCRIPT_DIR}/wait-for-health.sh"

post_json_expect_success "Create user" "${ORDER_FLOW_CREATE_USER_URL}" "${ORDER_FLOW_CREATE_USER_PAYLOAD}"
post_json_expect_success "Create order" "${ORDER_FLOW_CREATE_ORDER_URL}" "${ORDER_FLOW_CREATE_ORDER_PAYLOAD}"

echo "[INFO] Order flow smoke test completed."
