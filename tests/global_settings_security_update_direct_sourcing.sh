#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/global_settings.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_global_settings_direct.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

UPDATE_CALL_COUNT=0
UPDATE_SAW_FORCE=""
UPDATE_SAW_READY=""
UPDATE_SAW_DEFERRED=""

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_equals() {
  local expected="${1:-}" actual="${2:-}" message="${3:-values differ}"
  if [ "$expected" != "$actual" ]; then
    fail_test "${message} (expected '${expected}', got '${actual}')"
  fi
}

function assert_unset_or_empty() {
  local value="${1:-}" message="${2:-value should be unset or empty}"
  [ -z "$value" ] || fail_test "$message (got '${value}')"
}

function capture_docker_logs() { :; }
function log_msg() { :; }

function update_nginx_config() {
  UPDATE_CALL_COUNT=$((UPDATE_CALL_COUNT + 1))
  UPDATE_SAW_FORCE="${DOCKISTRATE_FORCE_NGINX_RECREATE:-}"
  UPDATE_SAW_READY="${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-}"
  UPDATE_SAW_DEFERRED="${DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE:-}"
}

function reset_test_state() {
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config

  UPDATE_CALL_COUNT=0
  UPDATE_SAW_FORCE=""
  UPDATE_SAW_READY=""
  UPDATE_SAW_DEFERRED=""
  unset DOCKISTRATE_FORCE_NGINX_RECREATE
  unset DOCKISTRATE_SECURITY_NGINX_READY_CHECK
  unset DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE
  unset SKIP_UPDATE_NGINX_CONFIG
}

if declare -F update_nginx_config_for_security_change >/dev/null 2>&1; then
  fail_test "global_settings direct sourcing should not load security_rules update helper"
fi

reset_test_state
set_acl_status 403 >/dev/null
assert_equals "1" "$UPDATE_CALL_COUNT" "set_acl_status should update nginx config once"
assert_equals "true" "$UPDATE_SAW_FORCE" "set_acl_status should force nginx recreate during update"
assert_equals "true" "$UPDATE_SAW_READY" "set_acl_status should request readiness during immediate update"
assert_unset_or_empty "${UPDATE_SAW_DEFERRED:-}" "set_acl_status should not mark a deferred update during immediate update"
assert_unset_or_empty "${DOCKISTRATE_FORCE_NGINX_RECREATE:-}" "set_acl_status should restore force recreate flag"
assert_unset_or_empty "${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-}" "set_acl_status should restore readiness flag"

reset_test_state
DOCKISTRATE_FORCE_NGINX_RECREATE="previous-force"
DOCKISTRATE_SECURITY_NGINX_READY_CHECK="previous-ready"
set_security_rule_status 451 >/dev/null
assert_equals "1" "$UPDATE_CALL_COUNT" "set_security_rule_status should update nginx config once"
assert_equals "true" "$UPDATE_SAW_FORCE" "set_security_rule_status should force nginx recreate during update"
assert_equals "true" "$UPDATE_SAW_READY" "set_security_rule_status should request readiness during immediate update"
assert_equals "previous-force" "${DOCKISTRATE_FORCE_NGINX_RECREATE:-}" "set_security_rule_status should restore previous force flag"
assert_equals "previous-ready" "${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-}" "set_security_rule_status should restore previous readiness flag"

reset_test_state
SKIP_UPDATE_NGINX_CONFIG=true
set_security_rule_status 418 >/dev/null
assert_equals "1" "$UPDATE_CALL_COUNT" "deferred set_security_rule_status should still call update helper"
assert_equals "true" "$UPDATE_SAW_FORCE" "deferred update should force nginx recreate for final update"
assert_unset_or_empty "$UPDATE_SAW_READY" "deferred update should not request immediate readiness"
assert_equals "true" "$UPDATE_SAW_DEFERRED" "deferred update should mark deferred security recreate"
assert_unset_or_empty "${DOCKISTRATE_FORCE_NGINX_RECREATE:-}" "deferred update should restore force recreate flag"
assert_unset_or_empty "${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-}" "deferred update should restore readiness flag"
assert_equals "true" "${DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE:-}" "deferred security recreate marker should remain for final update"

echo "Global settings security update direct sourcing checks passed."
