#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/global_csv.sh"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_restore_settings.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT
BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
TRACE="$TMP_ROOT/trace"
OUTPUT="$TMP_ROOT/output"
BACKUP_SOURCE="$TMP_ROOT/input-backup"
RECOVERY_DIR="$TMP_ROOT/recovery-config"
OLD_IMAGE='registry.example.com:5000/team/current:1'
NEW_IMAGE='registry.example.com:5000/team/restored:2'
FAIL_STAGE=''

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function record_action() { printf '%s\n' "$*" >>"$TRACE"; }
function confirm_prompt() { return 0; }
function ensure_no_nginx_container_conflict() { record_action conflict; }
function nginx_container_is_managed() { return 0; }
function container_running() { return 0; }
function begin_transaction() {
  record_action transaction
  cp -R "$CONFIG_DIR" "$RECOVERY_DIR"
}
function _nginx_prepare_runtime_rollback() {
  record_action prepare
  [ "$FAIL_STAGE" != prepare ]
}
function _nginx_release_runtime_rollback() { record_action release; }
function end_transaction_success() {
  record_action commit
  [ "$FAIL_STAGE" != commit ]
}
function _rollback_handler() {
  record_action rollback
  rm -rf "$CONFIG_DIR"
  cp -R "$RECOVERY_DIR" "$CONFIG_DIR"
  load_config || return 1
  return 1
}
function fix_permissions() {
  record_action permissions
  [ "$FAIL_STAGE" != permissions ]
}
function update_nginx_config() {
  record_action "render:${NGINX_IMAGE}:${CLIENT_IP_HEADER}"
  [ "$FAIL_STAGE" != render ]
}
function recreate_nginx_container() {
  record_action "recreate:$1"
  [ "$FAIL_STAGE" != recreate ]
}
function check_config() {
  record_action check
  [ "$FAIL_STAGE" != check ]
}
function log_msg() { :; }

function reset_fixture() {
  rm -rf "$STATE_DIR" "$BACKUP_SOURCE" "$RECOVERY_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$BACKUP_SOURCE/config"
  : >"$TRACE"
  config_reset_defaults
  NGINX_IMAGE="$OLD_IMAGE"
  CLIENT_IP_HEADER='X-Current-Client'
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf 'original\n' >"$CONFIG_DIR/marker"
  (
    NGINX_IMAGE="$NEW_IMAGE"
    CLIENT_IP_HEADER='X-Restored-Client'
    _save_config_write_rows >"$BACKUP_SOURCE/config/global_settings.csv"
  )
  printf 'restored\n' >"$BACKUP_SOURCE/config/marker"
  SKIP_DOCKER_CHECKS=false
  FAIL_STAGE=''
}

function assert_current_state() {
  grep -qx original "$CONFIG_DIR/marker" || fail_test 'rejected restore changed current files'
  [ "$NGINX_IMAGE" = "$OLD_IMAGE" ] || fail_test 'rejected restore changed loaded image'
  [ "$CLIENT_IP_HEADER" = X-Current-Client ] || fail_test 'rejected restore changed loaded headers'
}

function assert_private_snapshots_cleaned() {
  local candidate
  for candidate in "$TMP_DIR"/restore_*; do
    [ ! -e "$candidate" ] || fail_test 'restore left a private snapshot behind'
  done
}

# Validate the complete private snapshot before conflict probes or transactions.
for invalid_case in image header late_duplicate backend_http inheritance; do
  reset_fixture
  case "$invalid_case" in
  image) test_global_csv_seed "$BACKUP_SOURCE/config/global_settings.csv" NGINX_IMAGE -p80:80 ;;
  header) test_global_csv_seed "$BACKUP_SOURCE/config/global_settings.csv" CLIENT_IP_HEADER 'X-Client;include /tmp/payload' ;;
  late_duplicate) duplicate_record="$(tail -n 1 "$BACKUP_SOURCE/config/global_settings.csv")"; printf '%s\n' "$duplicate_record" >>"$BACKUP_SOURCE/config/global_settings.csv" ;;
  backend_http) printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 'example.com,http2;include /tmp/payload' >"$BACKUP_SOURCE/config/backend_http_versions.csv" ;;
  inheritance) printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 'alias.example.com,yes,perhaps,yes,yes,yes' >"$BACKUP_SOURCE/config/dedicated_host_inheritance.csv" ;;
  esac
  cp "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/before-settings"
  if restore_backup "$BACKUP_SOURCE" >"$OUTPUT" 2>&1; then
    fail_test "$invalid_case restore accepted invalid settings"
  fi
  [ ! -s "$TRACE" ] || fail_test "$invalid_case restore reached runtime probes or transaction"
  cmp -s "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/before-settings" || fail_test 'preflight rejection changed settings file'
  assert_current_state
  assert_private_snapshots_cleaned
  grep -Eq 'Invalid|Duplicate' "$OUTPUT" || fail_test 'preflight rejection lacked a validation diagnostic'
done

# Valid restored globals must be loaded before rendering or container refresh.
reset_fixture
restore_backup "$BACKUP_SOURCE" >"$OUTPUT" 2>&1 || fail_test 'valid restore failed'
grep -qx "render:${NEW_IMAGE}:X-Restored-Client" "$TRACE" || fail_test 'render used stale global settings'
grep -qx "recreate:${NEW_IMAGE}" "$TRACE" || fail_test 'recreation used stale image'
grep -qx restored "$CONFIG_DIR/marker" || fail_test 'valid restore did not copy snapshot'
[ "$NGINX_IMAGE" = "$NEW_IMAGE" ] || fail_test 'valid restore did not publish image'
assert_private_snapshots_cleaned

# An incomplete old snapshot keeps the existing in-memory global defaults.
reset_fixture
rm "$BACKUP_SOURCE/config/global_settings.csv"
restore_backup "$BACKUP_SOURCE" >"$OUTPUT" 2>&1 || fail_test 'snapshot without global settings failed'
grep -qx "render:${OLD_IMAGE}:X-Current-Client" "$TRACE" || fail_test 'incomplete snapshot changed current global settings'
assert_private_snapshots_cleaned

# Caller conditionals suppress errexit: every failed stage must still stop and
# roll back. Transaction doubles restore files/globals without exiting the test.
for FAIL_STAGE in prepare permissions render recreate check commit; do
  failure="$FAIL_STAGE"
  reset_fixture
  FAIL_STAGE="$failure"
  if restore_backup "$BACKUP_SOURCE" >"$OUTPUT" 2>&1; then
    fail_test "$FAIL_STAGE failure became a successful restore"
  fi
  grep -qx rollback "$TRACE" || fail_test "$FAIL_STAGE failure did not request rollback"
  if grep -qx release "$TRACE"; then fail_test "$FAIL_STAGE failure released runtime recovery"; fi
  assert_current_state
  assert_private_snapshots_cleaned
done
printf 'Restore settings preflight checks passed (5 malformed snapshots, 2 valid restores, 6 failure stages).\n'
