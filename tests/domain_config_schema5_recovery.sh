#!/usr/bin/env bash
# Fixture settings are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
source "$ROOT_DIR/lib/security_rules.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-schema5-recovery.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
TEST_COMPLETE=false
# Bash3 can exit a function on an unset empty-array expansion while preserving
# status zero. Require the end marker as well as the shell status on every exit.
trap 'test_status=$?; rm -rf "$TEST_WORK"; if [ "$TEST_COMPLETE" != true ] && [ "$test_status" -eq 0 ]; then test_status=1; fi; exit "$test_status"' EXIT
STATE_DIR="$TEST_WORK/state"; TMP_DIR="$STATE_DIR/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
TRANSACTION_LOCK_HELD=true SKIP_DOCKER_CHECKS=true
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function _transaction_lock_pid_running() { return 1; }
function restore_backup_archive() {
  [ "$1" = "$TEST_WORK/archive" ] && [ "$#" = 1 ] || return 1
  printf '%s\n' "$TEST_RESTORED_SCHEMA" >"$CONFIG_DIR/state_schema_version"
  printf 'restore\n' >>"$TEST_WORK/actions"
}
function verify_recovery_codec() {
  local expected_domain="$TEST_EXPECTED_SCHEMA" expected_cols=47
  [ "$expected_domain" -ge 3 ] || expected_domain=3
  [ "$TEST_EXPECTED_SCHEMA" != 5 ] || expected_cols=48
  [ "$DOMAIN_CONFIG_INPUT_SCHEMA_VERSION" = "$expected_domain" ] || fail_test 'Recovery selected wrong domain codec'
  [ "$STATE_SECURITY_RULES_COLS" = "$expected_cols" ] || fail_test 'Recovery selected wrong aggregate codec'
  local config="$TEST_WORK/rules" _dc_config="$TEST_WORK/rules" _dc_domain=example.com _dc_output="$TEST_WORK/compiled"
  mkdir -p "$config" "$_dc_output"
  _domain_csv_write_header "$config/security_rules.csv"
  if [ "$TEST_EXPECTED_SCHEMA" = 5 ]; then
    csv_join_row rule-1 1 1 block single 403 - auto >>"$config/security_rules.csv"
  else
    csv_join_row rule-1 1 1 single 403 - auto >>"$config/security_rules.csv"
  fi
  _domain_csv_write_header "$config/security_conditions.csv"
  csv_join_row rule-1 1 header X-Access equals yes >>"$config/security_conditions.csv"
  : >"$_dc_output/.domain-security-rows"
  _domain_csv_read "$config/security_rules.csv" _domain_config_compile_rule || return 1
  csv_parse_line "$(cut -f2- "$_dc_output/.domain-security-rows")" || return 1
  [ "$CSV_FIELD_COUNT" = "$expected_cols" ] || fail_test 'Recovered rules lost historical aggregate format'
  if [ "$TEST_EXPECTED_SCHEMA" = 5 ]; then
    [ "${CSV_FIELDS[47]}" = block ] || fail_test 'Committed current cleanup reset an action'
  fi
}
function domain_config_runtime_rollback() {
  verify_recovery_codec || return 1
  printf 'rollback\n' >>"$TEST_WORK/actions"
  rm -rf "$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL
}
function domain_config_runtime_cleanup() {
  verify_recovery_codec || return 1
  printf 'cleanup\n' >>"$TEST_WORK/actions"
  rm -rf "$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL
}

# A named journal retains wire version3. Active recovery follows the restored
# marker; committed cleanup follows the current marker, not state_schema_before.
for scenario in active:3:5:3 active:4:5:4 committed:3:3:3 committed:4:4:4 committed:4:5:5; do
  IFS=: read -r phase previous current TEST_EXPECTED_SCHEMA <<<"$scenario"
  TEST_RESTORED_SCHEMA="$previous"
  printf '%s\n' "$current" >"$CONFIG_DIR/state_schema_version"
  journal="$(_domain_runtime_journal_root)/apply.fixture"
  mkdir -p "$journal/operations"
  _domain_runtime_header "$journal/transaction.csv" >"$journal/transaction.csv"
  csv_join_row 3 "$previous" 99999999 "$TEST_WORK/archive" 0 "$phase" no >>"$journal/transaction.csv"
  printf 'position,path,originally_missing\n' >"$journal/targets.csv"
  : >"$TEST_WORK/actions"
  domain_config_runtime_recover
  [ ! -e "$journal" ] || fail_test 'Recovery left completed fixture journal'
  [ "$STATE_SECURITY_RULES_COLS" = 48 ] || fail_test 'Recovery leaked historical aggregate scope'
  if [ "$phase" = active ]; then
    [ "$(cat "$TEST_WORK/actions")" = "$(printf 'restore\nrollback')" ] || fail_test 'Active journal did not restore first'
    [ "$(cat "$CONFIG_DIR/state_schema_version")" = "$previous" ] || fail_test 'Recovery silently migrated restored state'
  else
    [ "$(cat "$TEST_WORK/actions")" = cleanup ] || fail_test 'Committed journal rolled back'
    [ "$(cat "$CONFIG_DIR/state_schema_version")" = "$current" ] || fail_test 'Cleanup rewrote schema marker'
  fi
done
TEST_COMPLETE=true
printf '[PASS] Schema5 journal recovery selects domain and aggregate codecs together\n'
