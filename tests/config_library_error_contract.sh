#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

set +e
probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/global_settings.sh"
  source "$ROOT_DIR/lib/http_version.sh"

  set_auto_backups maybe
  rc_auto=$?
  echo "rc_auto=$rc_auto"
  echo after-auto

  set_http_version bogus
  rc_http=$?
  echo "rc_http=$rc_http"
  echo after-http
' bash "$ROOT_DIR" 2>&1)"
probe_status=$?
set -e

[ "$probe_status" -eq 0 ] || fail_test "library probe shell should continue running after invalid library calls"
grep -Fqx 'rc_auto=1' <<<"$probe_output" || fail_test "set_auto_backups should return status 1 on invalid input"
grep -Fqx 'after-auto' <<<"$probe_output" || fail_test "set_auto_backups should not exit the shell on invalid input"
grep -Fqx 'rc_http=1' <<<"$probe_output" || fail_test "set_http_version should return status 1 on invalid input"
grep -Fqx 'after-http' <<<"$probe_output" || fail_test "set_http_version should not exit the shell on invalid input"

set +e
transaction_probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/backups.sh"
  source "$ROOT_DIR/lib/global_settings.sh"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_error_contract.XXXXXX")"
  trap "rm -rf \"$TMP_ROOT\"" EXIT

  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config || exit 1

  update_nginx_config() { return 1; }

  if set_real_ip_recursive off; then
    rc_txn=0
  else
    rc_txn=$?
  fi
  echo "rc_txn=$rc_txn"
  if transaction_is_active; then
    echo transaction-active
  else
    echo transaction-inactive
  fi
  echo after-transaction
' bash "$ROOT_DIR" 2>&1)"
transaction_probe_status=$?
set -e

[ "$transaction_probe_status" -eq 0 ] || fail_test "transaction cleanup probe shell should continue after rollback-return path"
grep -Fqx 'rc_txn=1' <<<"$transaction_probe_output" || fail_test "transaction failure should return status 1"
grep -Fqx 'transaction-inactive' <<<"$transaction_probe_output" || fail_test "transaction failure should release the transaction state"
grep -Fqx 'after-transaction' <<<"$transaction_probe_output" || fail_test "transaction failure should not exit the shell"

set +e
direct_transaction_probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/backups.sh"
  source "$ROOT_DIR/lib/global_settings.sh"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_error_contract.XXXXXX")"
  trap "rm -rf \"$TMP_ROOT\"" EXIT

  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config || exit 1

  update_nginx_config() { return 1; }

  set_real_ip_recursive off
  rc_direct=$?
  echo "rc_direct=$rc_direct"
  if transaction_is_active; then
    echo transaction-active-direct
  else
    echo transaction-inactive-direct
  fi
  echo after-direct-transaction
' bash "$ROOT_DIR" 2>&1)"
direct_transaction_probe_status=$?
set -e

[ "$direct_transaction_probe_status" -eq 0 ] || fail_test "direct transaction failure probe should leave the shell alive"
grep -Fqx 'rc_direct=1' <<<"$direct_transaction_probe_output" || fail_test "direct transaction failure should still report status 1"
grep -Fqx 'transaction-inactive-direct' <<<"$direct_transaction_probe_output" || fail_test "direct transaction failure should release the transaction state"
grep -Fqx 'after-direct-transaction' <<<"$direct_transaction_probe_output" || fail_test "direct transaction failure should not exit the shell"
! grep -Fq '[Error] transaction failed. Rolled back.' <<<"$direct_transaction_probe_output" || fail_test "direct transaction failure should not trigger a second rollback trap"

set +e
caller_trap_failure_probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/backups.sh"
  source "$ROOT_DIR/lib/global_settings.sh"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_error_contract.XXXXXX")"

  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config || exit 1

  update_nginx_config() { return 1; }

  trap "echo caller-err-failure" ERR
  trap "echo caller-exit-failure; rm -rf \"$TMP_ROOT\"" EXIT

  set_real_ip_recursive off >/dev/null 2>&1 || true
  echo after-failure-setter
  false >/dev/null 2>&1
  echo after-failure-false
' bash "$ROOT_DIR" 2>&1)"
caller_trap_failure_probe_status=$?
set -e

[ "$caller_trap_failure_probe_status" -eq 0 ] || fail_test "rollback-return probe should preserve caller traps and keep the shell alive"
grep -Fqx 'after-failure-setter' <<<"$caller_trap_failure_probe_output" || fail_test "failing library call should return control to the caller"
grep -Fqx 'after-failure-false' <<<"$caller_trap_failure_probe_output" || fail_test "caller shell should continue after probing preserved traps"
grep -Fqx 'caller-err-failure' <<<"$caller_trap_failure_probe_output" || fail_test "rollback-return path should preserve caller ERR traps"
grep -Fqx 'caller-exit-failure' <<<"$caller_trap_failure_probe_output" || fail_test "rollback-return path should preserve caller EXIT traps"

set +e
caller_trap_success_probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/backups.sh"
  source "$ROOT_DIR/lib/global_settings.sh"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_error_contract.XXXXXX")"

  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config || exit 1

  update_nginx_config() { return 0; }

  trap "echo caller-err-success" ERR
  trap "echo caller-exit-success; rm -rf \"$TMP_ROOT\"" EXIT

  set_real_ip_recursive off >/dev/null 2>&1 || exit 1
  echo after-success-setter
  false >/dev/null 2>&1
  echo after-success-false
' bash "$ROOT_DIR" 2>&1)"
caller_trap_success_probe_status=$?
set -e

[ "$caller_trap_success_probe_status" -eq 0 ] || fail_test "successful library transaction should preserve caller traps and keep the shell alive"
grep -Fqx 'after-success-setter' <<<"$caller_trap_success_probe_output" || fail_test "successful library call should return control to the caller"
grep -Fqx 'after-success-false' <<<"$caller_trap_success_probe_output" || fail_test "caller shell should continue after successful library call"
grep -Fqx 'caller-err-success' <<<"$caller_trap_success_probe_output" || fail_test "successful return-mode transaction should preserve caller ERR traps"
grep -Fqx 'caller-exit-success' <<<"$caller_trap_success_probe_output" || fail_test "successful return-mode transaction should preserve caller EXIT traps"

set +e
subshell_trap_probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/backups.sh"
  source "$ROOT_DIR/lib/global_settings.sh"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_error_contract.XXXXXX")"
  marker_dir="$TMP_ROOT/marker"
  mkdir -p "$marker_dir"

  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config || exit 1

  update_nginx_config() { return 1; }

  trap "[ -d \"$marker_dir\" ] && touch \"$marker_dir/inherited-exit\"" EXIT

  (
    set +e
    set_real_ip_recursive off >/dev/null 2>&1 || true
  )
  echo "subshell_rc=$?"
  if [ -e "$marker_dir/inherited-exit" ]; then
    echo inherited-exit-reactivated
  else
    echo inherited-exit-inactive
  fi
  trap - EXIT
  rm -rf "$TMP_ROOT"
' bash "$ROOT_DIR" 2>&1)"
subshell_trap_probe_status=$?
set -e

[ "$subshell_trap_probe_status" -eq 0 ] || fail_test "subshell trap probe should complete successfully"
grep -Fqx 'subshell_rc=0' <<<"$subshell_trap_probe_output" || fail_test "failing library call in subshell should still return control to the subshell caller"
grep -Fqx 'inherited-exit-inactive' <<<"$subshell_trap_probe_output" || fail_test "return-mode rollback should not reactivate inherited EXIT traps in subshells"

set +e
rollback_handler_probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/backups.sh"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_error_contract.XXXXXX")"
  trap "rm -rf \"$TMP_ROOT\"" EXIT

  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config || exit 1

  eval "$(declare -f csv_join_row | sed '\''1s/csv_join_row/original_csv_join_row/'\'')"
  _csv_join_row_fail_after=4
  csv_join_row() {
    _csv_join_row_call_count=$((_csv_join_row_call_count + 1))
    if [ "${_csv_join_row_call_count}" -eq "${_csv_join_row_fail_after}" ]; then
      return 1
    fi
    original_csv_join_row "$@"
  }

  begin_transaction "rollback_handler_probe" "$CONFIG_DIR" || exit 1
  HTTP_VERSION="http2"
  if save_config || _rollback_handler; then
    echo rollback-handler-continued
    rc_handler=0
  else
    echo rollback-handler-stopped
    rc_handler=1
  fi
  echo "rc_handler=$rc_handler"
  if transaction_is_active; then
    echo transaction-active-handler
  else
    echo transaction-inactive-handler
  fi
  echo after-rollback-handler
' bash "$ROOT_DIR" 2>&1)"
rollback_handler_probe_status=$?
set -e

[ "$rollback_handler_probe_status" -eq 0 ] || fail_test "rollback handler probe shell should continue after nested rollback"
grep -Fqx 'rollback-handler-stopped' <<<"$rollback_handler_probe_output" || fail_test "inactive _rollback_handler should still fail the caller path"
grep -Fqx 'rc_handler=1' <<<"$rollback_handler_probe_output" || fail_test "save_config || _rollback_handler should report failure after inner rollback"
grep -Fqx 'transaction-inactive-handler' <<<"$rollback_handler_probe_output" || fail_test "nested rollback should clear the transaction state"
grep -Fqx 'after-rollback-handler' <<<"$rollback_handler_probe_output" || fail_test "nested rollback probe should not exit the shell"
! grep -Fq 'rollback-handler-continued' <<<"$rollback_handler_probe_output" || fail_test "inactive _rollback_handler must not let the caller continue on success"

set +e
save_commit_probe_output="$(bash -c '
  set +e
  ROOT_DIR="$1"
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/backups.sh"

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_error_contract.XXXXXX")"
  trap "rm -rf \"$TMP_ROOT\"" EXIT

  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config || exit 1
  cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.before"
  rm -f "$BACKUP_DIR/last_rollback_targets.sha256" "$BACKUP_DIR/last_rollback_state.sha256"

  eval "$(declare -f backup_files_only | sed '\''1s/backup_files_only/original_backup_files_only/'\'')"
  backup_files_only_counter_file="$TMP_ROOT/backup_files_only.count"
  printf "0\n" >"$backup_files_only_counter_file"
  backup_files_only() {
    local calls=0
    calls="$(cat "$backup_files_only_counter_file")"
    calls=$((calls + 1))
    printf "%s\n" "$calls" >"$backup_files_only_counter_file"
    if [ "$calls" -eq 1 ]; then
      original_backup_files_only "$@"
      return
    fi
    return 1
  }

  HTTP_VERSION="http2"
  save_config
  rc_commit=$?
  echo "rc_commit=$rc_commit"
  if cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.before"; then
    echo commit-rollback-restored
  fi
  if transaction_is_active; then
    echo transaction-active-commit
  else
    echo transaction-inactive-commit
  fi
  echo after-save-commit
' bash "$ROOT_DIR" 2>&1)"
save_commit_probe_status=$?
set -e

[ "$save_commit_probe_status" -eq 0 ] || fail_test "standalone save_config commit failure probe should leave the shell alive"
grep -Fqx 'rc_commit=1' <<<"$save_commit_probe_output" || fail_test "standalone save_config commit failure should return status 1"
grep -Fqx 'commit-rollback-restored' <<<"$save_commit_probe_output" || fail_test "standalone save_config commit failure should restore the original file"
grep -Fqx 'transaction-inactive-commit' <<<"$save_commit_probe_output" || fail_test "standalone save_config commit failure should clear the transaction state"
grep -Fqx 'after-save-commit' <<<"$save_commit_probe_output" || fail_test "standalone save_config commit failure should not exit the shell"

echo "config library error contract checks passed."
