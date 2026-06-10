#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/capture/start_capture.sh
source "$ROOT_DIR/lib/capture/start_capture.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_start_capture_tls_state.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

BASE_DIR="$tmp_dir"
STATE_DIR="$tmp_dir/state"
CONFIG_DIR="$STATE_DIR/config"
CAPTURE_DIR="$STATE_DIR/pcaps"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
CAPTURE_IMAGE="capture:test"
NGINX_IMAGE="nginx:test"
NGINX_CONTAINER_NAME="nginx-proxy"
INTERACTIVE=false
SKIP_DOCKER_CHECKS=false

RECREATE_STATUS=0

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function require_valid_var_name() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}
function is_valid_image_ref() { return 0; }
function require_managed_nginx_container() { return 0; }
function container_running() { return 0; }
function _capture_is_true() { [ "${1:-}" = "true" ]; }
function acknowledge_tls_decrypt_capture() { :; }
function enable_capture_tls_decrypt() {
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "enabled" >"$CAPTURE_TLS_STATE_FILE"
}
function disable_capture_tls_decrypt() {
  rm -f "$CAPTURE_TLS_STATE_FILE"
}
function recreate_nginx_container() {
  return "$RECREATE_STATUS"
}
function remove_container_and_anonymous_volumes() { :; }
function docker() { :; }
function normalize_domain() { printf '%s\n' "${1:-}"; }
function is_valid_ipv4() { return 0; }

function run_failure_case() {
  local recreate_status="$1" expected_state="$2" expected_message="$3"
  local output="" status=0

  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$CAPTURE_DIR"
  RECREATE_STATUS="$recreate_status"

  output="$(start_capture pcaps/test-capture --tls-decrypt 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    fail "start_capture should fail when recreate_nginx_container returns ${recreate_status}."
  fi

  case "$expected_state" in
  present)
    [ -f "$CAPTURE_TLS_STATE_FILE" ] || fail "TLS decrypt state should be preserved for recreate status ${recreate_status}."
    ;;
  absent)
    [ ! -f "$CAPTURE_TLS_STATE_FILE" ] || fail "TLS decrypt state should be cleared for recreate status ${recreate_status}."
    ;;
  esac

  if ! printf '%s' "$output" | grep -Fq "$expected_message"; then
    printf '%s\n' "$output" >&2
    fail "expected output to include: ${expected_message}"
  fi
}

run_failure_case 1 absent "Failed to recreate Nginx with TLS decrypt key logging enabled."
run_failure_case 2 present "TLS decrypt state preserved because Nginx may already be running with key logging enabled."

echo "start-capture TLS recreate state handling checks passed."
