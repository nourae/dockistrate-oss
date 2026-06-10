#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/nginx/recreate_nginx_container.sh
source "$ROOT_DIR/lib/nginx/recreate_nginx_container.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_recreate_post_launch.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

NGINX_IMAGE="nginx:test"
NGINX_CONTAINER_NAME="nginx-proxy"
DEFAULT_NETWORK="dockistrate-net"
NGINX_CONFIG_DIR="$tmp_dir/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
NGINX_CONTAINER_CONF_ROOT="/etc/nginx/dockistrate"
NGINX_CONTAINER_MAIN_CONF="/etc/nginx/dockistrate/nginx.conf"
ACME_WEBROOT_DIR="$tmp_dir/acme"
CERTS_DIR="$tmp_dir/certs"
NGINX_DOCKER_OPTS=""
DOCKISTRATE_MANAGED_LABEL_KEY="com.dockistrate.managed"
DOCKISTRATE_ROLE_LABEL_KEY="com.dockistrate.role"
DOCKISTRATE_ROLE_PROXY="proxy"
DOCKISTRATE_STATE_DIR_LABEL_KEY="com.dockistrate.state-dir"

docker_calls=0
add_network_calls=0

function normalize_nginx_image() { printf '%s\n' "${1:-}"; }
function ensure_no_nginx_container_conflict() { return 0; }
function get_all_mapped_port_bindings() { return 0; }
function ensure_network_exists() { return 0; }
function create_nginx_config() { mkdir -p "$NGINX_CONFIG_DIR"; : >"$NGINX_CONFIG_DIR/nginx.conf"; }
function nginx_container_is_managed() { return 0; }
function container_running() { return 1; }
function pull_image_if_autopull() { return 0; }
function _nginx_mark_runtime_rollback_needed() { return 0; }
function _nginx_expected_state_dir_label() { printf '%s\n' "$tmp_dir"; }
function remove_container_and_anonymous_volumes() { return 0; }
function add_nginx_networks() {
  add_network_calls=$((add_network_calls + 1))
  return 1
}
function log_msg() { :; }
function docker() {
  docker_calls=$((docker_calls + 1))
  return 0
}

status=0
recreate_nginx_container "$NGINX_IMAGE" >/dev/null 2>&1 || status=$?

if [ "$status" -ne 2 ]; then
  echo "[Error] post-launch recreate failure should return status 2, got ${status}." >&2
  exit 1
fi

if [ "$docker_calls" -ne 1 ]; then
  echo "[Error] expected docker run to execute once before post-launch failure, got ${docker_calls}." >&2
  exit 1
fi

if [ "$add_network_calls" -ne 1 ]; then
  echo "[Error] expected add_nginx_networks to run once after launch, got ${add_network_calls}." >&2
  exit 1
fi

echo "recreate-nginx post-launch failure status checks passed."
