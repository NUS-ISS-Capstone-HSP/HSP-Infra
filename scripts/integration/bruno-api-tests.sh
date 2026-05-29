#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

API_TESTS_ENABLED="${BRUNO_API_TESTS_ENABLED:-true}"
if [[ "${API_TESTS_ENABLED}" != "true" ]]; then
  echo "[INFO] BRUNO_API_TESTS_ENABLED=false, skipping Bruno API tests."
  exit 0
fi

if [[ -z "${BRUNO_API_BASE_URL:-}" ]]; then
  if [[ -n "${PROD_API_BASE_URL:-}" ]]; then
    BRUNO_API_BASE_URL="${PROD_API_BASE_URL}"
  else
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/env/dev.env"
    BRUNO_API_BASE_URL="http://localhost:${NGINX_HOST_PORT}"
  fi
fi

BRUNO_API_BASE_URL="${BRUNO_API_BASE_URL%/}"
if [[ -z "${BRUNO_HEALTH_PATH:-}" ]]; then
  if [[ "${BRUNO_API_BASE_URL}" == *":8081" || "${BRUNO_API_BASE_URL}" == *":8081/" ]]; then
    BRUNO_HEALTH_PATH="/healthz"
  else
    BRUNO_HEALTH_PATH="/api/healthz"
  fi
fi

BRUNO_CLI_PACKAGE="${BRUNO_CLI_PACKAGE:-@usebruno/cli@2.10.1}"
BRUNO_COLLECTION_DIR="${ROOT_DIR}/bruno/hsp-core-flow"
API_TEST_REPORT_DIR="${API_TEST_REPORT_DIR:-${ROOT_DIR}/reports/api-interface}"

mkdir -p "${API_TEST_REPORT_DIR}"

echo "[INFO] Running Bruno API tests against ${BRUNO_API_BASE_URL}"
(
  cd "${BRUNO_COLLECTION_DIR}"
  npx --yes "${BRUNO_CLI_PACKAGE}" run \
    --env-var "baseUrl=${BRUNO_API_BASE_URL}" \
    --env-var "healthPath=${BRUNO_HEALTH_PATH}" \
    --reporter-json "${API_TEST_REPORT_DIR}/results.json" \
    --reporter-junit "${API_TEST_REPORT_DIR}/results.xml" \
    --reporter-html "${API_TEST_REPORT_DIR}/index.html" \
    --reporter-skip-all-headers
)

echo "[INFO] Bruno API test report written to ${API_TEST_REPORT_DIR}/index.html"
