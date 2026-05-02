#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_cmd docker
load_env dev

echo "[INFO] Starting MySQL in debug mode (host port exposed)..."
compose_cmd -f "${ROOT_DIR}/docker-compose.yml" -f "${ROOT_DIR}/docker-compose.debug.yml" up -d mysql

echo "[INFO] MySQL started on localhost:${MYSQL_HOST_PORT}."
echo "[INFO] Persistent data is stored in Docker volume: mysql-data (not in git workspace)."
