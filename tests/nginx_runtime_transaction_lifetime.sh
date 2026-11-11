#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_runtime_lifetime.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
BASE_DIR="$(_realpath_portable "$TEST_ROOT")"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
BACKUP_DIR="$STATE_DIR/backups"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
NGINX_CONTAINER_NAME=lifetime-proxy

# Keep the real transaction archives, file restoration, saved settings, hooks,
# and commit metadata. Only container operations and selected faults are mocked.
eval "$(declare -f backup_files_only | sed '1s/backup_files_only/_test_backup_files_only/')"
eval "$(declare -f finalize_temp_file | sed '1s/finalize_temp_file/_test_finalize_temp_file/')"
function backup_files_only() {
  case "${FAULT:-}:$1" in post_backup:post_*) return 1 ;; esac
  _test_backup_files_only "$@"
}
function finalize_temp_file() {
  if [ "${FAULT:-}" = metadata ] && [ "$1" = "$LAST_POST_BACKUP_FILE" ]; then return 1; fi
  _test_finalize_temp_file "$@"
}
function log_msg() { :; }
function capture_docker_logs() { :; }
function nginx_container_is_managed() { [ "$MODEL_EXISTS" = true ]; }
function nginx_container_exists_any() { [ "$MODEL_EXISTS" = true ]; }
function container_running() { [ "$MODEL_EXISTS" = true ] && [ "$MODEL_RUNNING" = true ]; }
function container_published_port_bindings() { printf '%s\n' "$MODEL_BINDINGS"; }
function normalize_nginx_image() { printf '%s\n' "$1"; }
function docker() {
  if [ "$#" -eq 4 ] && [ "$1" = inspect ] && [ "$2" = -f ] && [ "$3" = '{{.Config.Image}}' ]; then
    printf '%s\n' "$MODEL_IMAGE"
  elif [ "$#" -eq 2 ] && [ "$1" = stop ] && [ "$2" = "$NGINX_CONTAINER_NAME" ]; then
    MODEL_RUNNING=false
  else
    printf '[Error] Unexpected mocked Docker command: %s\n' "$*" >&2
    return 1
  fi
}
function remove_container_and_anonymous_volumes() {
  MODEL_EXISTS=false
  MODEL_RUNNING=false
  MODEL_POLICY=''
  MODEL_IMAGE=''
  MODEL_BINDINGS=''
}
function recreate_nginx_container() {
  _nginx_mark_runtime_rollback_needed
  MODEL_EXISTS=true
  MODEL_RUNNING=true
  MODEL_IMAGE="$1"
  MODEL_BINDINGS="${2:-8443/tcp}"
  MODEL_POLICY="$ACL_POLICY"
  MODEL_RECREATES=$((MODEL_RECREATES + 1))
}
function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function assert_equal() {
  [ "$1" = "$2" ] || fail_test "$3: expected '$1', got '$2'"
}
function assert_cleared() {
  ! transaction_is_active || fail_test 'Transaction retained after completion'
  [ -z "${NGINX_RUNTIME_ROLLBACK_DEPTH:-}${NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED:-}${NGINX_RUNTIME_ROLLBACK_IMAGE:-}${NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED:-}${NGINX_RUNTIME_ROLLBACK_WAS_RUNNING:-}${NGINX_RUNTIME_ROLLBACK_BINDINGS:-}${ROLLBACK_PRE_HOOK:-}" ] ||
    fail_test 'Runtime snapshot or hooks retained after completion'
}
function reset_case() {
  assert_cleared
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$ERROR_LOG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  ACL_POLICY=deny
  NGINX_IMAGE=nginx:1.31.7
  FAULT=''
  save_config
  cp "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/before.csv"
  MODEL_EXISTS="${1:-true}"
  MODEL_RUNNING="${2:-true}"
  MODEL_IMAGE=nginx:1.31.7
  MODEL_POLICY=deny
  MODEL_BINDINGS=443/tcp
  MODEL_RECREATES=0
}
function replace_proxy_for_policy() {
  _nginx_prepare_runtime_rollback "$NGINX_IMAGE"
  ACL_POLICY="$1"
  save_config
  recreate_nginx_container "$NGINX_IMAGE"
  # Config generation releases its own runtime scope before the outer setter
  # commits its transaction. Recovery must remain available until that commit.
  _nginx_release_runtime_rollback
}
function fail_commit() {
  FAULT="$1"
  if end_transaction_success >"$BASE_DIR/failure.log" 2>&1; then
    fail_test "Commit unexpectedly succeeded for $FAULT"
  fi
  grep -Fq 'Rolled back.' "$BASE_DIR/failure.log" || {
    cat "$BASE_DIR/failure.log" >&2
    fail_test 'Commit failure did not complete rollback'
  }
  FAULT=''
  cmp -s "$BASE_DIR/before.csv" "$GLOBAL_SETTINGS_FILE" || fail_test 'Rollback changed original settings'
  assert_equal deny "$ACL_POLICY" 'Rollback did not reload original settings'
  assert_cleared
}

for failure in post_backup metadata; do
  reset_case
  begin_transaction_return "lifetime_${failure}" "$CONFIG_DIR"
  replace_proxy_for_policy allow
  fail_commit "$failure"
  assert_equal deny "$MODEL_POLICY" 'Rollback left attempted ACL policy in running proxy'
  assert_equal nginx:1.31.7 "$MODEL_IMAGE" 'Rollback changed original image'
  assert_equal 443/tcp "$MODEL_BINDINGS" 'Rollback changed original bindings'
  assert_equal true "$MODEL_RUNNING" 'Rollback did not restore running proxy'
  assert_equal 2 "$MODEL_RECREATES" 'Rollback must recreate original runtime'
  printf '[tests] PASS: outer %s failure restores config and runtime\n' "$failure"
done

reset_case false false
begin_transaction_return lifetime_absent "$CONFIG_DIR"
replace_proxy_for_policy allow
fail_commit post_backup
assert_equal false "$MODEL_EXISTS" 'Rollback created a previously absent proxy'
assert_equal 1 "$MODEL_RECREATES" 'Absent runtime must not be recreated during rollback'
printf '[tests] PASS: previously absent proxy remains absent after rollback\n'

reset_case true false
begin_transaction_return lifetime_stopped "$CONFIG_DIR"
replace_proxy_for_policy allow
fail_commit metadata
assert_equal true "$MODEL_EXISTS" 'Rollback lost previously stopped proxy'
assert_equal false "$MODEL_RUNNING" 'Rollback started previously stopped proxy'
assert_equal deny "$MODEL_POLICY" 'Stopped proxy rollback retained attempted policy'
assert_equal 443/tcp "$MODEL_BINDINGS" 'Stopped proxy rollback lost original bindings'
printf '[tests] PASS: previously stopped proxy remains stopped after rollback\n'

reset_case
begin_transaction_return lifetime_success "$CONFIG_DIR"
replace_proxy_for_policy allow
end_transaction_success
assert_equal allow "$MODEL_POLICY" 'Successful commit did not retain new runtime policy'
assert_equal allow "$ACL_POLICY" 'Successful commit did not retain new saved policy'
assert_cleared
# A later transaction must capture the newly committed runtime, never reuse the
# prior transaction's original deny policy or lose its recovery hook.
cp "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/committed.csv"
begin_transaction_return lifetime_sequential "$CONFIG_DIR"
replace_proxy_for_policy deny
FAULT=metadata
if end_transaction_success >"$BASE_DIR/failure.log" 2>&1; then fail_test 'Sequential commit fault ignored'; fi
FAULT=''
cmp -s "$BASE_DIR/committed.csv" "$GLOBAL_SETTINGS_FILE" || fail_test 'Sequential rollback lost committed settings'
assert_equal allow "$MODEL_POLICY" 'Sequential rollback reused stale runtime policy'
assert_equal allow "$ACL_POLICY" 'Sequential rollback did not restore committed policy'
assert_equal 3 "$MODEL_RECREATES" 'Sequential rollback must recover current snapshot'
assert_cleared
printf '[tests] PASS: successful and sequential transactions keep distinct snapshots\n'

reset_case
begin_transaction_return lifetime_nested "$CONFIG_DIR"
_nginx_prepare_runtime_rollback "$NGINX_IMAGE"
begin_transaction_return lifetime_nested_inner "$CONFIG_DIR"
replace_proxy_for_policy allow
assert_equal 1 "${NGINX_RUNTIME_ROLLBACK_DEPTH:-}" 'Inner runtime release lost outer snapshot'
end_transaction_success
transaction_is_active || fail_test 'Inner transaction committed its outer transaction'
_nginx_release_runtime_rollback
fail_commit metadata
assert_equal deny "$MODEL_POLICY" 'Nested rollback lost original runtime policy'
assert_equal 2 "$MODEL_RECREATES" 'Nested rollback must restore runtime exactly once'
printf '[tests] PASS: nested runtime and transaction scopes retain original snapshot\n'

reset_case
begin_transaction_return lifetime_multiple_updates "$CONFIG_DIR"
replace_proxy_for_policy allow
replace_proxy_for_policy deny
replace_proxy_for_policy allow
fail_commit post_backup
assert_equal deny "$MODEL_POLICY" 'Multiple updates replaced original rollback snapshot'
assert_equal 4 "$MODEL_RECREATES" 'Multiple updates should recover original runtime once'
printf '[tests] PASS: repeated updates in one transaction preserve original snapshot\n'

# A runtime scope used without a transaction still has its explicit lifetime.
reset_case
_nginx_prepare_runtime_rollback "$NGINX_IMAGE"
_nginx_release_runtime_rollback
assert_cleared
printf '[tests] PASS: standalone runtime scope releases immediately\n'
