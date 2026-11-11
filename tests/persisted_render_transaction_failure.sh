#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_render_transaction.XXXXXX")"
  trap 'rm -rf "$TMP_ROOT"' EXIT
  for test_case in conditional interactive nested return_mode no_transaction callback_exit callback_return; do
    case_dir="$TMP_ROOT/$test_case"
    mkdir -p "$case_dir"
    status=0
    "$BASH" "${BASH_SOURCE[0]}" "$test_case" "$case_dir" >"$case_dir/output" 2>&1 || status=$?
    case "$test_case" in
    conditional | interactive | nested | callback_exit) expected=1 ;;
    *) expected=0 ;;
    esac
    if [ "$status" -ne "$expected" ]; then
      cat "$case_dir/output" >&2
      echo "[Error] ${test_case}: expected status ${expected}, got ${status}" >&2
      exit 1
    fi
    for file in global_settings.csv backend_http_versions.csv backend_acl_statuses.csv marker; do
      cmp -s "$case_dir/before/$file" "$case_dir/state/config/$file" || {
        echo "[Error] ${test_case}: failed preflight changed ${file}" >&2
        exit 1
      }
    done
    case "$test_case" in
    callback_*) [ -f "$case_dir/render-called" ] || { echo '[Error] Callback failure did not run renderer' >&2; exit 1; } ;;
    *) [ ! -e "$case_dir/render-called" ] || { echo '[Error] Failed preflight invoked renderer' >&2; exit 1; } ;;
    esac
    [ ! -e "$case_dir/continued" ] || { echo '[Error] Failed exit-mode command continued' >&2; exit 1; }
    [ ! -e "$(cat "$case_dir/lockpath")" ] || { echo '[Error] Failed preflight retained lock' >&2; exit 1; }
    case "$test_case" in
    no_transaction) ;;
    *) grep -Fq 'Rolled back.' "$case_dir/output" || { cat "$case_dir/output" >&2; exit 1; } ;;
    esac
    # A later process must acquire a fresh transaction and retain its commit.
    "$BASH" "${BASH_SOURCE[0]}" later "$case_dir" >"$case_dir/later-output" 2>&1 || {
      cat "$case_dir/later-output" >&2
      exit 1
    }
    grep -qx later-operation "$case_dir/state/config/marker" || exit 1
    printf '[tests] PASS: persisted render preflight %s\n' "$test_case"
  done
  exit 0
fi

[ "$#" -eq 2 ] || exit 2
TEST_CASE="$1"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/nginx/update_nginx_config.sh
source "$ROOT_DIR/lib/nginx/update_nginx_config.sh"
# shellcheck source=../lib/http_version/set_backend_http_version.sh
source "$ROOT_DIR/lib/http_version/set_backend_http_version.sh"
# shellcheck source=../lib/global_settings/set_real_ip_recursive.sh
source "$ROOT_DIR/lib/global_settings/set_real_ip_recursive.sh"
# shellcheck source=../lib/cli/command_visibility.sh
source "$ROOT_DIR/lib/cli/command_visibility.sh"
# shellcheck source=../lib/cli/run_command.sh
source "$ROOT_DIR/lib/cli/run_command.sh"

BASE_DIR="$(_realpath_portable "$2")"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
BACKUP_DIR="$STATE_DIR/backups"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
NGINX_CONTAINER_NAME=render-preflight-proxy
GLOBAL_SETTINGS_INFO_PREFIX='[Info]'
GLOBAL_SETTINGS_USAGE_PREFIX='[Usage]'
SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
VERBOSE=false
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$ERROR_LOG_DIR" "$BACKUP_DIR"
printf '%s\n' "$(_transaction_lock_dir)" >"$BASE_DIR/lockpath"

function log_msg() { :; }
function audit_log() { :; }
function capture_docker_logs() { :; }
function create_backup() { :; }
function domain_exists() { [ "$1" = example.com ]; }
function _update_nginx_config_from_validated_settings() {
  : >"$BASE_DIR/render-called"
  printf 'partial-render\n' >"$CONFIG_DIR/marker"
  return 9
}
function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function assert_transaction_cleared() {
  ! transaction_is_active || fail_test 'Preflight retained active transaction'
  [ ! -e "$(_transaction_lock_dir)" ] || fail_test 'Preflight retained transaction lock'
  [ -z "${ROLLBACK_DESC:-}${PRE_CHANGE_BACKUP:-}${TRANSACTION_DEPTH:-}${TRANSACTION_OWNER_PID:-}${TRANSACTION_MODE:-}" ] ||
    fail_test 'Preflight retained transaction metadata'
}

if [ "$TEST_CASE" = later ]; then
  load_config
  begin_transaction later "$CONFIG_DIR"
  printf 'later-operation\n' >"$CONFIG_DIR/marker"
  end_transaction_success
  assert_transaction_cleared
  exit 0
fi

_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 'example.com,http1.1' >"$BACKEND_HTTP_FILE"
printf '%s\n' "$STATE_BACKEND_ACL_STATUSES_HEADER" 'example.com,not-a-status' >"$BACKEND_ACL_STATUS_FILE"
case "$TEST_CASE" in
callback_*) printf '%s\n' "$STATE_BACKEND_ACL_STATUSES_HEADER" 'example.com,403' >"$BACKEND_ACL_STATUS_FILE" ;;
esac
printf 'before\n' >"$CONFIG_DIR/marker"
mkdir -p "$BASE_DIR/before"
cp "$CONFIG_DIR"/* "$BASE_DIR/before/"

case "$TEST_CASE" in
conditional | callback_exit)
  if set_backend_http_version example.com http2; then :; fi
  : >"$BASE_DIR/continued"
  ;;
interactive)
  INTERACTIVE=true
  if ! run_command set-backend-http-version example.com http2; then :; fi
  : >"$BASE_DIR/continued"
  ;;
nested)
  begin_transaction parent_mutation "$CONFIG_DIR"
  printf 'parent-change\n' >"$CONFIG_DIR/marker"
  if ! set_backend_http_version example.com http2; then :; fi
  : >"$BASE_DIR/continued"
  ;;
return_mode | callback_return)
  # Real library caller must return nonzero, preserve caller traps, and reload
  # globals after rollback instead of terminating the embedding shell.
  trap ':' EXIT
  caller_trap="$(trap -p EXIT)"
  if set_real_ip_recursive off; then fail_test 'Return-mode setter succeeded'; fi
  assert_transaction_cleared
  [ "$REAL_IP_RECURSIVE" = on ] || fail_test 'Rollback did not reload globals'
  [ "$(trap -p EXIT)" = "$caller_trap" ] || fail_test 'Return-mode rollback cleared caller trap'
  trap - EXIT
  ;;
no_transaction)
  if update_nginx_config; then fail_test 'Unowned render preflight succeeded'; fi
  assert_transaction_cleared
  [ -z "$(trap -p ERR)$(trap -p EXIT)" ] || fail_test 'Unowned preflight installed traps'
  ;;
*) exit 2 ;;
esac
