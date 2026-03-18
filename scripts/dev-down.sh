#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_cmd docker
load_env dev

extra_args=(--remove-orphans)
if [[ "${1:-}" == "--volumes" ]]; then
  extra_args+=(--volumes)
fi

echo "[INFO] Stopping HSP infra stack in dev mode..."
compose_cmd -f "${ROOT_DIR}/docker-compose.yml" down "${extra_args[@]}"

echo "[INFO] Stack stopped."
