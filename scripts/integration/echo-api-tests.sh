#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NGINX_CONF="${ROOT_DIR}/nginx/conf.d/default.conf"

ECHO_TEST_BASE_URL="${ECHO_TEST_BASE_URL:-http://localhost:8080}"
ECHO_TEST_MAX_ATTEMPTS="${ECHO_TEST_MAX_ATTEMPTS:-20}"
ECHO_TEST_RETRY_INTERVAL_SECONDS="${ECHO_TEST_RETRY_INTERVAL_SECONDS:-3}"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] Missing command: ${cmd}" >&2
    exit 1
  fi
}

extract_service_prefixes() {
  if [[ ! -f "${NGINX_CONF}" ]]; then
    echo "[ERROR] Missing nginx config: ${NGINX_CONF}" >&2
    exit 1
  fi

  mapfile -t SERVICE_PREFIXES < <(
    awk '/^[[:space:]]*location[[:space:]]+\/api\/[^[:space:]]+\/[[:space:]]*\{/{print $2}' "${NGINX_CONF}" \
      | sed -E 's#/$##' \
      | sort -u
  )

  if (( ${#SERVICE_PREFIXES[@]} == 0 )); then
    echo "[ERROR] No /api/* routes found in ${NGINX_CONF}" >&2
    exit 1
  fi
}

request_with_retry() {
  local method="$1"
  local url="$2"
  local expected_code="$3"
  local response_file="$4"
  local payload="${5:-}"

  local code="000"
  local attempt=1

  while (( attempt <= ECHO_TEST_MAX_ATTEMPTS )); do
    if [[ "${method}" == "POST" ]]; then
      code="$(curl -sS --connect-timeout 5 --max-time 20 \
        -o "${response_file}" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data "${payload}" \
        "${url}" || true)"
    else
      code="$(curl -sS --connect-timeout 5 --max-time 20 \
        -o "${response_file}" -w '%{http_code}' \
        -X GET \
        "${url}" || true)"
    fi

    if [[ "${code}" == "${expected_code}" ]]; then
      return 0
    fi

    if (( attempt == ECHO_TEST_MAX_ATTEMPTS )); then
      break
    fi

    sleep "${ECHO_TEST_RETRY_INTERVAL_SECONDS}"
    attempt=$((attempt + 1))
  done

  echo "[FAIL] ${method} ${url} expected HTTP ${expected_code}, got ${code}" >&2
  echo "[DEBUG] Response body:" >&2
  cat "${response_file}" >&2 || true
  return 1
}

assert_echo_fields() {
  local response_file="$1"
  local expected_message="$2"
  local context="$3"

  local id message source created_at
  id="$(jq -r '.id // empty' "${response_file}")"
  message="$(jq -r '.message // empty' "${response_file}")"
  source="$(jq -r '.source // empty' "${response_file}")"
  created_at="$(jq -r '.created_at // empty' "${response_file}")"

  if [[ -z "${id}" ]]; then
    echo "[FAIL] ${context}: missing id" >&2
    cat "${response_file}" >&2
    return 1
  fi

  if [[ "${message}" != "${expected_message}" ]]; then
    echo "[FAIL] ${context}: message mismatch, expected '${expected_message}', got '${message}'" >&2
    cat "${response_file}" >&2
    return 1
  fi

  if [[ -z "${source}" || "${source}" != "HTTP" ]]; then
    echo "[FAIL] ${context}: invalid source '${source}', expected 'HTTP'" >&2
    cat "${response_file}" >&2
    return 1
  fi

  if [[ -z "${created_at}" ]]; then
    echo "[FAIL] ${context}: missing created_at" >&2
    cat "${response_file}" >&2
    return 1
  fi
}

run_echo_rw_test() {
  local service_prefix="$1"
  local base_url="$2"
  local message="hello http ${service_prefix}"
  local post_url="${base_url}${service_prefix}/v1/echo"

  local post_response_file get_response_file
  post_response_file="$(mktemp)"
  get_response_file="$(mktemp)"

  local payload
  payload="$(jq -nc --arg message "${message}" '{"message": $message}')"

  request_with_retry "POST" "${post_url}" "201" "${post_response_file}" "${payload}"
  assert_echo_fields "${post_response_file}" "${message}" "POST ${post_url}"

  local id
  id="$(jq -r '.id // empty' "${post_response_file}")"
  if [[ -z "${id}" ]]; then
    echo "[FAIL] POST ${post_url}: missing id for follow-up GET" >&2
    cat "${post_response_file}" >&2
    rm -f "${post_response_file}" "${get_response_file}"
    return 1
  fi

  local get_url="${post_url}/${id}"
  request_with_retry "GET" "${get_url}" "200" "${get_response_file}"
  assert_echo_fields "${get_response_file}" "${message}" "GET ${get_url}"

  echo "[PASS] ${service_prefix} echo rw test passed (id=${id})"
  rm -f "${post_response_file}" "${get_response_file}"
}

require_cmd curl
require_cmd jq
require_cmd awk
require_cmd sed

ECHO_TEST_BASE_URL="${ECHO_TEST_BASE_URL%/}"
extract_service_prefixes

echo "[INFO] Base URL: ${ECHO_TEST_BASE_URL}"
echo "[INFO] Echo routes from nginx: ${SERVICE_PREFIXES[*]}"

for service_prefix in "${SERVICE_PREFIXES[@]}"; do
  run_echo_rw_test "${service_prefix}" "${ECHO_TEST_BASE_URL}"
done

echo "[INFO] Echo API interface tests completed."
