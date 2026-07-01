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
tamper_after_mkdir_path=""
tamper_after_mkdir_target=""
tamper_after_keylog_guard_name=""
tamper_after_keylog_guard_target=""
tamper_after_state_guard_name=""
tamper_after_state_guard_target=""
fail_mkdir_path=""
tamper_before_cd_path=""
tamper_before_cd_target=""

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
  tamper_after_mkdir_path=""
  tamper_after_mkdir_target=""
  tamper_after_keylog_guard_name=""
  tamper_after_keylog_guard_target=""
  tamper_after_state_guard_name=""
  tamper_after_state_guard_target=""
  fail_mkdir_path=""
  tamper_before_cd_path=""
  tamper_before_cd_target=""
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
function date() {
  case "${1:-}" in
  '+%Y%m%d_%H%M%S')
    printf '%s\n' "20260701_120000"
    ;;
  '+%Y-%m-%dT%H:%M:%S%z')
    printf '%s\n' "2026-07-01T12:00:00+0000"
    ;;
  *)
    command date "$@"
    ;;
  esac
}
function mkdir() {
  local status=0 arg=""
  if [ -n "$fail_mkdir_path" ]; then
    for arg in "$@"; do
      [ "$arg" = "-p" ] && continue
      if [ "$arg" = "$fail_mkdir_path" ]; then
        fail_mkdir_path=""
        return 1
      fi
    done
  fi
  command mkdir "$@" || status=$?
  if [ "$status" -eq 0 ] && [ -n "$tamper_after_mkdir_path" ]; then
    for arg in "$@"; do
      [ "$arg" = "-p" ] && continue
      if [ "$arg" = "$tamper_after_mkdir_path" ]; then
        command rm -rf "$tamper_after_mkdir_path"
        command ln -s "$tamper_after_mkdir_target" "$tamper_after_mkdir_path"
        tamper_after_mkdir_path=""
        tamper_after_mkdir_target=""
        break
      fi
    done
  fi
  return "$status"
}
function cd() {
  local arg="" target="" physical=false
  for arg in "$@"; do
    case "$arg" in
    -P)
      physical=true
      ;;
    -*)
      ;;
    *)
      target="$arg"
      ;;
    esac
  done
  if [ "$physical" = true ] && [ -n "$tamper_before_cd_path" ] && [ "$target" = "$tamper_before_cd_path" ]; then
    command rm -rf "$tamper_before_cd_path"
    command ln -s "$tamper_before_cd_target" "$tamper_before_cd_path"
    tamper_before_cd_path=""
    tamper_before_cd_target=""
  fi
  builtin cd "$@"
}

eval "$(declare -f _capture_tls_cd_guarded_keylog_dir | sed '1s/_capture_tls_cd_guarded_keylog_dir/_orig_capture_tls_cd_guarded_keylog_dir/')"
eval "$(declare -f _capture_tls_cd_guarded_state_dir | sed '1s/_capture_tls_cd_guarded_state_dir/_orig_capture_tls_cd_guarded_state_dir/')"

function _capture_tls_cd_guarded_keylog_dir() {
  _orig_capture_tls_cd_guarded_keylog_dir "$@" || return 1
  if [ -n "$tamper_after_keylog_guard_name" ]; then
    command ln -sf "$tamper_after_keylog_guard_target" "$tamper_after_keylog_guard_name"
    tamper_after_keylog_guard_name=""
    tamper_after_keylog_guard_target=""
  fi
  return 0
}

function _capture_tls_cd_guarded_state_dir() {
  _orig_capture_tls_cd_guarded_state_dir "$@" || return 1
  if [ -n "$tamper_after_state_guard_name" ]; then
    command ln -sf "$tamper_after_state_guard_target" "$tamper_after_state_guard_name"
    tamper_after_state_guard_name=""
    tamper_after_state_guard_target=""
  fi
  return 0
}

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
outside_enable_keylog_dir="$tmp_dir/outside-enable-keylog"
mkdir -p "$outside_enable_keylog_dir"
tamper_after_mkdir_path="$CAPTURE_DIR/tls-keys"
tamper_after_mkdir_target="$outside_enable_keylog_dir"
if enable_capture_tls_decrypt "test=keylog-swap" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should reject a symlinked keylog directory swapped after mkdir."
fi
if find "$outside_enable_keylog_dir" -type f | grep -q .; then
  fail "enable_capture_tls_decrypt wrote a keylog file through a swapped keylog directory."
fi
[ ! -e "$CAPTURE_TLS_STATE_FILE" ] || fail "failed keylog swap should not write TLS decrypt state."

reset_runtime
outside_enable_config_dir="$tmp_dir/outside-enable-config"
mkdir -p "$outside_enable_config_dir"
tamper_after_mkdir_path="$CONFIG_DIR"
tamper_after_mkdir_target="$outside_enable_config_dir"
if enable_capture_tls_decrypt "test=state-swap" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should reject a symlinked state directory swapped after mkdir."
fi
[ ! -f "$outside_enable_config_dir/capture_tls_decrypt.state" ] || fail "enable_capture_tls_decrypt wrote TLS state through a swapped config directory."

reset_runtime
in_tree_keylog_cd_target="$CAPTURE_DIR/tls-keys-cd-target"
mkdir -p "$in_tree_keylog_cd_target"
tamper_before_cd_path="$CAPTURE_DIR/tls-keys"
tamper_before_cd_target="$in_tree_keylog_cd_target"
if enable_capture_tls_decrypt "test=keylog-cd-symlink-swap" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should reject a keylog directory symlinked immediately before guarded cd."
fi
if find "$in_tree_keylog_cd_target" -type f | grep -q .; then
  fail "enable_capture_tls_decrypt wrote a keylog file through a late keylog directory symlink swap."
fi
[ ! -e "$CAPTURE_TLS_STATE_FILE" ] || fail "late keylog cd symlink swap should not write TLS decrypt state."

reset_runtime
in_tree_state_cd_target="$STATE_DIR/config-cd-target"
mkdir -p "$in_tree_state_cd_target"
tamper_before_cd_path="$CONFIG_DIR"
tamper_before_cd_target="$in_tree_state_cd_target"
if enable_capture_tls_decrypt "test=state-cd-symlink-swap" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should reject a state directory symlinked immediately before guarded cd."
fi
[ ! -f "$in_tree_state_cd_target/capture_tls_decrypt.state" ] || fail "enable_capture_tls_decrypt wrote TLS state through a late state directory symlink swap."

reset_runtime
outside_enable_keylog_file="$tmp_dir/outside-enable-keylog-file"
printf '%s\n' "keep-keylog" >"$outside_enable_keylog_file"
tamper_after_keylog_guard_name="tlskeys_20260701_120000.log"
tamper_after_keylog_guard_target="$outside_enable_keylog_file"
enable_capture_tls_decrypt "test=keylog-file-swap" >/dev/null 2>&1 || fail "enable_capture_tls_decrypt should tolerate a keylog filename symlink swap."
[ "$(cat "$outside_enable_keylog_file")" = "keep-keylog" ] || fail "enable_capture_tls_decrypt followed a swapped keylog filename symlink."
[ -f "$CAPTURE_DIR/tls-keys/tlskeys_20260701_120000.log" ] || fail "enable_capture_tls_decrypt should create the intended keylog file."
[ ! -L "$CAPTURE_DIR/tls-keys/tlskeys_20260701_120000.log" ] || fail "enable_capture_tls_decrypt should replace a swapped keylog filename symlink."

reset_runtime
outside_enable_state_file="$tmp_dir/outside-enable-state-file"
printf '%s\n' "keep-state" >"$outside_enable_state_file"
tamper_after_state_guard_name="capture_tls_decrypt.state"
tamper_after_state_guard_target="$outside_enable_state_file"
enable_capture_tls_decrypt "test=state-file-swap" >/dev/null 2>&1 || fail "enable_capture_tls_decrypt should tolerate a state filename symlink swap."
[ "$(cat "$outside_enable_state_file")" = "keep-state" ] || fail "enable_capture_tls_decrypt followed a swapped state filename symlink."
[ -f "$CAPTURE_TLS_STATE_FILE" ] || fail "enable_capture_tls_decrypt should create the intended TLS state file."
[ ! -L "$CAPTURE_TLS_STATE_FILE" ] || fail "enable_capture_tls_decrypt should replace a swapped TLS state filename symlink."

reset_runtime
saved_umask="$(umask)"
umask 022
expected_umask="$(umask)"
fail_mkdir_path="$CAPTURE_DIR/tls-keys"
if enable_capture_tls_decrypt "test=keylog-mkdir-failure" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should fail when keylog directory creation fails."
fi
[ "$(umask)" = "$expected_umask" ] || fail "keylog mkdir failure should restore umask."
umask "$saved_umask"
[ ! -e "$CAPTURE_TLS_STATE_FILE" ] || fail "keylog mkdir failure should not write TLS decrypt state."

reset_runtime
saved_umask="$(umask)"
umask 022
expected_umask="$(umask)"
fail_mkdir_path="$CONFIG_DIR"
if enable_capture_tls_decrypt "test=state-mkdir-failure" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should fail when state directory creation fails."
fi
[ "$(umask)" = "$expected_umask" ] || fail "state mkdir failure should restore umask."
umask "$saved_umask"
[ ! -e "$CAPTURE_TLS_STATE_FILE" ] || fail "state mkdir failure should not write TLS decrypt state."

reset_runtime
keylog_dirname="$CAPTURE_DIR/tls-keys/tlskeys_20260701_120000.log"
mkdir -p "$keylog_dirname"
if enable_capture_tls_decrypt "test=keylog-directory-destination" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should reject a keylog destination that is a directory."
fi
[ -d "$keylog_dirname" ] || fail "keylog directory destination should remain a directory."
if find "$keylog_dirname" -type f | grep -q .; then
  fail "enable_capture_tls_decrypt moved a temp keylog file into an existing directory."
fi
[ ! -e "$CAPTURE_TLS_STATE_FILE" ] || fail "keylog directory destination failure should not write TLS decrypt state."

reset_runtime
mkdir -p "$CAPTURE_TLS_STATE_FILE"
if enable_capture_tls_decrypt "test=state-directory-destination" >/dev/null 2>&1; then
  fail "enable_capture_tls_decrypt should reject a TLS state destination that is a directory."
fi
[ -d "$CAPTURE_TLS_STATE_FILE" ] || fail "TLS state directory destination should remain a directory."
if find "$CAPTURE_TLS_STATE_FILE" -type f | grep -q .; then
  fail "enable_capture_tls_decrypt moved a temp state file into an existing directory."
fi

reset_runtime
valid_keylog_dir="$CAPTURE_DIR/tls-keys"
valid_keylog_file="$valid_keylog_dir/tlskeys.log"
outside_mount_keylog_dir="$tmp_dir/outside-mount-keylog"
if capture_tls_prepare_keylog_for_mount keylog_name "$outside_mount_keylog_dir" "$valid_keylog_file" >/dev/null 2>&1; then
  fail "capture_tls_prepare_keylog_for_mount should reject an out-of-tree keylog directory."
fi
[ ! -e "$outside_mount_keylog_dir" ] || fail "capture_tls_prepare_keylog_for_mount created an out-of-tree keylog directory."

reset_runtime
valid_keylog_dir="$CAPTURE_DIR/tls-keys"
valid_keylog_file="$valid_keylog_dir/tlskeys.log"
noncanonical_mount_keylog_dir="$CAPTURE_DIR/tls-keys-extra"
if capture_tls_prepare_keylog_for_mount keylog_name "$noncanonical_mount_keylog_dir" "$valid_keylog_file" >/dev/null 2>&1; then
  fail "capture_tls_prepare_keylog_for_mount should reject a non-canonical keylog directory."
fi
[ ! -e "$noncanonical_mount_keylog_dir" ] || fail "capture_tls_prepare_keylog_for_mount created a non-canonical keylog directory."

reset_runtime
valid_keylog_dir="$CAPTURE_DIR/tls-keys"
valid_keylog_file="$valid_keylog_dir/tlskeys.log"
outside_mount_swap_dir="$tmp_dir/outside-mount-swap"
mkdir -p "$outside_mount_swap_dir"
tamper_after_mkdir_path="$valid_keylog_dir"
tamper_after_mkdir_target="$outside_mount_swap_dir"
if capture_tls_prepare_keylog_for_mount keylog_name "$valid_keylog_dir" "$valid_keylog_file" >/dev/null 2>&1; then
  fail "capture_tls_prepare_keylog_for_mount should reject a keylog directory swapped after mkdir."
fi

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
