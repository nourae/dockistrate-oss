#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/nginx/recreate_nginx_container.sh
source "$ROOT_DIR/lib/nginx/recreate_nginx_container.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_recreate_keylog.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

NGINX_IMAGE="nginx:test"
NGINX_CONTAINER_NAME="nginx-proxy"
DEFAULT_NETWORK="dockistrate-net"
NGINX_CONFIG_DIR="$tmp_dir/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
ACME_WEBROOT_DIR="$tmp_dir/acme"
CERTS_DIR="$tmp_dir/certs"
NGINX_CAPTURE_KEYS_DIR="/var/log/nginx/keys"
SSLKEYLOG_LIB_BUILD_FILE="$tmp_dir/sslkeylogfile.so"
NGINX_SSLKEYLOG_LIB_PATH="/usr/local/lib/dockistrate/sslkeylogfile.so"
NGINX_DOCKER_OPTS=""

pull_calls=0
ensure_calls=0
remove_calls=0
rollback_mark_calls=0
docker_calls=0

function normalize_nginx_image() { printf '%s\n' "${1:-}"; }
function ensure_no_nginx_container_conflict() { return 0; }
function get_all_mapped_port_bindings() { return 0; }
function ensure_network_exists() { return 0; }
function create_nginx_config() { mkdir -p "$NGINX_CONFIG_DIR"; : >"$NGINX_CONFIG_DIR/nginx.conf"; }
function nginx_container_is_managed() { return 0; }
function container_running() { return 0; }
function container_published_port_bindings() { return 0; }
function pull_image_if_autopull() {
  pull_calls=$((pull_calls + 1))
  return 0
}
function capture_tls_decrypt_enabled() { return 0; }
function capture_tls_keylog_permissions() {
  printf -v "$1" '%s' "700"
  printf -v "$2" '%s' "600"
}
function capture_tls_keylog_host_dir() {
  printf -v "$1" '%s' "$tmp_dir/keys"
}
function capture_tls_keylog_file() {
  printf -v "$1" '%s' "$tmp_dir/keys/tlskeys.log"
}
function capture_tls_prepare_keylog_for_mount() {
  local __keylog_name_var="$1" keylog_dir="$2" keylog_file="$3"
  mkdir -p "$keylog_dir"
  printf -v "$__keylog_name_var" '%s' "${keylog_file##*/}"
}
function ensure_sslkeylog_library() {
  ensure_calls=$((ensure_calls + 1))
  return 1
}
function _nginx_mark_runtime_rollback_needed() {
  rollback_mark_calls=$((rollback_mark_calls + 1))
}
function remove_container_and_anonymous_volumes() {
  remove_calls=$((remove_calls + 1))
}
function docker() {
  docker_calls=$((docker_calls + 1))
  return 1
}

if recreate_nginx_container "$NGINX_IMAGE" >/dev/null 2>&1; then
  echo "[Error] recreate_nginx_container should fail when TLS keylog helper build fails." >&2
  exit 1
fi

if [ "$ensure_calls" -ne 1 ]; then
  echo "[Error] expected one helper build attempt, got ${ensure_calls}." >&2
  exit 1
fi

if [ "$remove_calls" -ne 0 ] || [ "$rollback_mark_calls" -ne 0 ]; then
  echo "[Error] nginx container should not be removed or marked for rollback before helper build succeeds." >&2
  exit 1
fi

if [ "$docker_calls" -ne 0 ]; then
  echo "[Error] docker run should not execute after helper build failure." >&2
  exit 1
fi

if [ "$pull_calls" -ne 1 ]; then
  echo "[Error] expected image pull preflight to run once before helper build." >&2
  exit 1
fi

echo "recreate-nginx TLS keylog build failure ordering checks passed."
