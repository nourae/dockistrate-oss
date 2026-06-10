#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/runtime_paths.sh
source "$ROOT_DIR/lib/runtime_paths.sh"
# shellcheck source=../lib/capture/common.sh
source "$ROOT_DIR/lib/capture/common.sh"
# shellcheck source=../lib/capture/stop_capture.sh
source "$ROOT_DIR/lib/capture/stop_capture.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_capture_tls_state_guard.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

BASE_DIR="$tmp_dir/base"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
CAPTURE_DIR="$STATE_DIR/pcaps"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
NGINX_IMAGE="nginx:test"
SKIP_DOCKER_CHECKS=false

recreate_calls=0
audit_calls=0

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
  *"$needle"*) ;;
  *) fail "${label}: expected output to contain '${needle}'." ;;
  esac
}

function assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
  *"$needle"*) fail "${label}: output should not contain '${needle}'." ;;
  esac
}

function reset_runtime() {
  rm -rf "$BASE_DIR"
  mkdir -p "$STATE_DIR" "$CAPTURE_DIR"
  recreate_calls=0
  audit_calls=0
  SKIP_DOCKER_CHECKS=false
}

function write_tls_state() {
  local keylog_file="$1"
  mkdir -p "$CONFIG_DIR"
  cat >"$CAPTURE_TLS_STATE_FILE" <<EOF
enabled=true
keylog_file=${keylog_file}
EOF
}

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function audit_log() {
  audit_calls=$((audit_calls + 1))
}
function recreate_nginx_container() {
  recreate_calls=$((recreate_calls + 1))
  return 0
}
function remove_container_and_anonymous_volumes() { :; }
function docker() { return 0; }

reset_runtime
outside_config="$tmp_dir/outside-config"
outside_keylog="$tmp_dir/outside-keylog.log"
mkdir -p "$outside_config"
: >"$outside_keylog"
rm -rf "$CONFIG_DIR"
ln -s "$outside_config" "$CONFIG_DIR"
cat >"$outside_config/capture_tls_decrypt.state" <<EOF
enabled=true
keylog_file=${outside_keylog}
EOF

if capture_tls_keylog_file keylog_file 2>/dev/null; then
  fail "capture_tls_keylog_file should reject symlinked TLS decrypt state."
fi
if capture_tls_decrypt_enabled >/dev/null 2>&1; then
  fail "capture_tls_decrypt_enabled should reject symlinked TLS decrypt state."
fi
if disable_capture_tls_decrypt "test=direct-disable" >/dev/null 2>&1; then
  fail "disable_capture_tls_decrypt should reject symlinked TLS decrypt state."
fi
[ -f "$outside_config/capture_tls_decrypt.state" ] || fail "direct disable deleted outside TLS decrypt state."

invalid_output_file="$tmp_dir/invalid-stop.out"
stop_capture >"$invalid_output_file" 2>&1
invalid_output="$(cat "$invalid_output_file")"
[ -f "$outside_config/capture_tls_decrypt.state" ] || fail "stop_capture deleted outside TLS decrypt state."
[ "$recreate_calls" -eq 0 ] || fail "stop_capture should not recreate Nginx for invalid TLS decrypt state."
assert_not_contains "$invalid_output" "TLS decrypt capture mode disabled." "invalid TLS state"

reset_runtime
valid_keylog_dir="$CAPTURE_DIR/tls-keys"
valid_keylog_file="$valid_keylog_dir/tlskeys.log"
mkdir -p "$valid_keylog_dir"
: >"$valid_keylog_file"
write_tls_state "$valid_keylog_file"

capture_tls_decrypt_enabled || fail "valid TLS decrypt state should be enabled."
capture_tls_decrypt_state_exists || fail "valid TLS decrypt state should exist."
valid_output_file="$tmp_dir/valid-stop.out"
stop_capture >"$valid_output_file" 2>&1
valid_output="$(cat "$valid_output_file")"
[ ! -e "$CAPTURE_TLS_STATE_FILE" ] || fail "valid TLS decrypt state should be removed."
[ "$recreate_calls" -eq 1 ] || fail "valid TLS decrypt stop should recreate Nginx once."
[ "$audit_calls" -eq 1 ] || fail "valid TLS decrypt stop should audit one disable event."
assert_contains "$valid_output" "TLS decrypt capture mode disabled." "valid TLS state"
assert_contains "$valid_output" "TLS key log preserved at: ${valid_keylog_file}" "valid TLS state"

echo "capture TLS state guard checks passed."
