#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_DIR="${ROOT_DIR}/env"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] Missing command: ${cmd}" >&2
    exit 1
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return
  fi

  echo "[ERROR] docker compose is not available" >&2
  exit 1
}

load_env() {
  local env_name="${1:-dev}"
  local env_file="${ENV_DIR}/${env_name}.env"
  local image_tag_file="${ENV_DIR}/image-tags.env"

  if [[ ! -f "${env_file}" ]]; then
    echo "[ERROR] Missing env file: ${env_file}" >&2
    exit 1
  fi

  if [[ ! -f "${image_tag_file}" ]]; then
    echo "[ERROR] Missing image tag file: ${image_tag_file}" >&2
    echo "        Copy env/image-tags.env.example to env/image-tags.env first." >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  # shellcheck disable=SC1090
  source "${image_tag_file}"
  set +a
}
