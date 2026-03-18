#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_cmd docker
load_env dev

echo "[INFO] Starting HSP infra stack in dev mode..."
compose_cmd -f "${ROOT_DIR}/docker-compose.yml" up -d --remove-orphans

echo "[INFO] Stack started."
