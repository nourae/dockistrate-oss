#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/nginx/start_nginx.sh
source "$ROOT_DIR/lib/nginx/start_nginx.sh"

save_config_calls=0
create_nginx_config_calls=0
update_nginx_config_calls=0
recreate_nginx_container_calls=0

function is_valid_image_ref() {
  return 0
}

function normalize_nginx_image() {
  printf '%s\n' "${1:-}"
}

function normalize_docker_opts_for_storage() {
  echo "[Error] forced nginx docker opts validation failure" >&2
  return 1
}

function save_config() {
  save_config_calls=$((save_config_calls + 1))
}

function create_nginx_config() {
  create_nginx_config_calls=$((create_nginx_config_calls + 1))
}

function update_nginx_config() {
  update_nginx_config_calls=$((update_nginx_config_calls + 1))
}

function recreate_nginx_container() {
  recreate_nginx_container_calls=$((recreate_nginx_container_calls + 1))
}

function container_exists() {
  return 1
}

function container_running() {
  return 1
}

NGINX_IMAGE="nginx:1.28.1"
NGINX_DOCKER_OPTS="--ulimit nofile=65535:65535"
GLOBAL_SETTINGS_FILE="/tmp/dockistrate_global_settings.csv"
NGINX_CONTAINER_NAME="nginx-proxy"
ERROR_LOG_DIR="/tmp/dockistrate-errors"

old_nginx_image="$NGINX_IMAGE"
old_nginx_docker_opts="$NGINX_DOCKER_OPTS"

set +e
output="$(start_nginx --nginx-image nginx:mainline --docker-opts "--cpus 1.5" 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] start-nginx should fail when docker options validation fails." >&2
  exit 1
fi

if ! grep -Fq "forced nginx docker opts validation failure" <<<"$output"; then
  echo "[Error] start-nginx failure output did not include the forced validation error." >&2
  exit 1
fi

if [ "$NGINX_IMAGE" != "$old_nginx_image" ]; then
  echo "[Error] start-nginx leaked in-memory NGINX_IMAGE on validation failure." >&2
  exit 1
fi

if [ "$NGINX_DOCKER_OPTS" != "$old_nginx_docker_opts" ]; then
  echo "[Error] start-nginx leaked in-memory NGINX_DOCKER_OPTS on validation failure." >&2
  exit 1
fi

if [ "$save_config_calls" -ne 0 ]; then
  echo "[Error] save_config should not be called when validation fails before commit." >&2
  exit 1
fi

if [ "$create_nginx_config_calls" -ne 0 ] || [ "$update_nginx_config_calls" -ne 0 ] || [ "$recreate_nginx_container_calls" -ne 0 ]; then
  echo "[Error] nginx runtime actions should not execute after validation failure." >&2
  exit 1
fi

echo "start-nginx validation failure does not leak global state checks passed."
