#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES=(
  certbot_symlink_round_trip
  checksum_failure_preserves_live_state
  missing_archive_preserves_live_state
  corrupt_archive_preserves_live_state
  extraction_failure_preserves_live_state
  absolute_symlink_preserves_live_state
  escaping_relative_symlink_preserves_live_state
  temporary_directory_target_round_trip
  hook_failure_is_reported
  replay_failure_restores_current_state
  missing_original_target_preserves_live_state
  overlapping_targets_preserve_nested_inodes
  exit_mode_failure_does_not_reenter
  absent_nested_target_remains_absent
  never_created_nested_target_remains_absent
  recovery_hook_sees_reloaded_config
  failed_config_reload_skips_recovery_hook
  aliased_missing_target_is_removed
  directory_metadata_round_trip
  directory_metadata_bsd_stat_round_trip
  directory_metadata_failure_restores_current_state
  directory_metadata_silent_failure_restores_current_state
  staging_group_failure_preserves_live_state
)

# Give each case a fresh shell so a failed rollback cannot leak transaction
# globals or traps into the next case. Continue to report all regressions.
if [ "$#" -eq 0 ]; then
  failed=0
  for test_case in "${CASES[@]}"; do
    if "$BASH" "${BASH_SOURCE[0]}" --case "$test_case"; then
      printf '[tests] PASS: transaction rollback %s\n' "$test_case"
    else
      printf '[tests] FAIL: transaction rollback %s\n' "$test_case" >&2
      failed=1
    fi
  done
  exit "$failed"
fi

if [ "$#" -ne 2 ] || [ "$1" != "--case" ]; then
  printf 'Usage: %s [--case case_name]\n' "$0" >&2
  exit 2
fi
case_found=false
for test_case in "${CASES[@]}"; do
  [ "$test_case" != "$2" ] || case_found=true
done
if [ "$case_found" != true ]; then
  printf '[Error] Unknown rollback test case: %s\n' "$2" >&2
  exit 2
fi

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_rollback_integrity.XXXXXX")")"
RETAINED_WORKSPACE=""
function cleanup() {
  if [ -n "$RETAINED_WORKSPACE" ]; then
    chmod -R u+rwX "$RETAINED_WORKSPACE" 2>/dev/null || true
    rm -rf "$RETAINED_WORKSPACE"
  fi
  chmod -R u+rwX "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
CERTS_DIR="$STATE_DIR/certs"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
BACKUP_DIR="$STATE_DIR/backups"
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
NGINX_CONTAINER_NAME="rollback-test-nginx"
ENABLE_AUTO_BACKUPS=true
ENABLE_BACKUP_COMPRESSION=true
BACKUP_RETENTION=0
SKIP_DOCKER_CHECKS=true
TRACE_FILE="$TMP_ROOT/trace.log"
ROLLBACK_OUTPUT="$TMP_ROOT/rollback.out"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$TMP_DIR" "$LOG_DIR" \
  "$ERROR_LOG_DIR" "$BACKUP_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR"
printf 'before\n' >"$CONFIG_DIR/marker.txt"
printf 'certificate-before\n' >"$CERTS_DIR/marker.pem"
: >"$TRACE_FILE"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  if [ -f "$ROLLBACK_OUTPUT" ]; then
    cat "$ROLLBACK_OUTPUT" >&2
  fi
  exit 1
}

function log_msg() {
  printf 'log: %s\n' "$*" >>"$TRACE_FILE"
}

function capture_docker_logs() { :; }

function load_config() {
  printf 'load_config\n' >>"$TRACE_FILE"
}

function assert_file_value() {
  local file="$1" expected="$2" actual=""
  [ -f "$file" ] || fail_test "Expected file is missing: $file"
  actual="$(cat "$file")"
  [ "$actual" = "$expected" ] || fail_test "Unexpected content in $file"
}

function file_inode() {
  local path="$1" inode=""
  if inode="$(stat -c '%i' "$path" 2>/dev/null)"; then
    printf '%s\n' "$inode"
  else
    stat -f '%i' "$path"
  fi
}

function file_mode() {
  local path="$1" mode=""
  mode="$(stat -c '%a' "$path" 2>/dev/null)" || mode="$(stat -f '%p' "$path")" || return 1
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  printf '%o\n' "$((8#$mode & 07777))"
}

function file_mtime() {
  local path="$1" mtime=""
  if mtime="$(stat -c '%Y' "$path" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
  else
    stat -f '%m' "$path"
  fi
}

function run_rollback() {
  # Return-mode rollback always reports the original operation's failure.
  # Calling it conditionally also verifies that safety does not rely on errexit.
  if _rollback_handler_return >"$ROLLBACK_OUTPUT" 2>&1; then
    fail_test "Return-mode rollback unexpectedly reported operation success"
  fi
  if transaction_is_active; then
    fail_test "Rollback left the transaction active"
  fi
  [ ! -e "$TMP_DIR/.dockistrate_transaction.lock" ] ||
    fail_test "Rollback left the transaction lock behind"
}

function assert_rollback_incomplete() {
  if grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" ||
    grep -Fq 'Rollback performed' "$TRACE_FILE"; then
    fail_test "Failed rollback reported successful recovery"
  fi
  if ! LC_ALL=C grep -Eiq '(rollback|roll back).*(fail|incomplete)|(fail|incomplete).*(rollback|roll back)' "$ROLLBACK_OUTPUT"; then
    fail_test "Failed rollback did not explain that recovery failed or is incomplete"
  fi
}

function begin_then_mutate() {
  begin_transaction_return integrity_failure "$CONFIG_DIR" "$CERTS_DIR" "$STATE_DIR/new-target"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  printf 'certificate-current\n' >"$CERTS_DIR/marker.pem"
  printf 'current-only\n' >"$CONFIG_DIR/current-only.txt"
  mkdir -p "$STATE_DIR/new-target"
  printf 'new-target-current\n' >"$STATE_DIR/new-target/marker.txt"
}

function assert_live_state_preserved() {
  assert_file_value "$CONFIG_DIR/marker.txt" current
  assert_file_value "$CERTS_DIR/marker.pem" certificate-current
  assert_file_value "$CONFIG_DIR/current-only.txt" current-only
  assert_file_value "$STATE_DIR/new-target/marker.txt" new-target-current
  assert_rollback_incomplete
}

function certbot_symlink_round_trip() {
  local archive_dir="$CERTS_DIR/letsencrypt/archive/example.com"
  local live_dir="$CERTS_DIR/letsencrypt/live/example.com"
  local part="" config_inode="" certs_inode=""
  mkdir -p "$archive_dir" "$live_dir"
  for part in cert chain fullchain privkey; do
    printf '%s-before\n' "$part" >"$archive_dir/${part}1.pem"
    ln -s "../../archive/example.com/${part}1.pem" "$live_dir/${part}.pem"
  done
  chmod 600 "$archive_dir/privkey1.pem"
  config_inode="$(file_inode "$CONFIG_DIR")"
  certs_inode="$(file_inode "$CERTS_DIR")"
  begin_transaction_return certbot_links "$CONFIG_DIR" "$CERTS_DIR"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  printf 'new\n' >"$CONFIG_DIR/new.txt"
  printf 'changed\n' >"$archive_dir/privkey1.pem"
  printf 'new-key\n' >"$archive_dir/privkey2.pem"
  rm -f "$live_dir/privkey.pem"
  ln -s '../../archive/example.com/privkey2.pem' "$live_dir/privkey.pem"

  run_rollback
  assert_file_value "$CONFIG_DIR/marker.txt" before
  [ ! -e "$CONFIG_DIR/new.txt" ] || fail_test "Rollback retained a new config file"
  [ ! -e "$archive_dir/privkey2.pem" ] || fail_test "Rollback retained a new Certbot archive file"
  for part in cert chain fullchain privkey; do
    [ -L "$live_dir/${part}.pem" ] || fail_test "Certbot live $part link was not restored"
    [ "$(readlink "$live_dir/${part}.pem")" = "../../archive/example.com/${part}1.pem" ] ||
      fail_test "Certbot live $part link changed its target"
    assert_file_value "$live_dir/${part}.pem" "${part}-before"
  done
  [ "$(file_mode "$archive_dir/privkey1.pem")" = 600 ] || fail_test "Rollback loosened private-key permissions"
  [ "$(file_inode "$CONFIG_DIR")" = "$config_inode" ] || fail_test "Rollback replaced the config directory inode"
  [ "$(file_inode "$CERTS_DIR")" = "$certs_inode" ] || fail_test "Rollback replaced the certificate directory inode"
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "Successful rollback was not reported"
}

function checksum_failure_preserves_live_state() {
  begin_then_mutate
  printf 'checksum-mismatch\n' >>"$PRE_CHANGE_BACKUP"
  run_rollback
  assert_live_state_preserved
}

function missing_archive_preserves_live_state() {
  begin_then_mutate
  rm -f "$PRE_CHANGE_BACKUP"
  run_rollback
  assert_live_state_preserved
}

function corrupt_archive_preserves_live_state() {
  begin_then_mutate
  printf 'not a gzip archive\n' >"$PRE_CHANGE_BACKUP"
  _write_backup_archive_checksum "$PRE_CHANGE_BACKUP"
  run_rollback
  assert_live_state_preserved
}

function extraction_failure_preserves_live_state() {
  begin_then_mutate
  function tar() {
    case "${1:-}" in
    -xzf | -xozf)
      printf 'extract_failed\n' >>"$TRACE_FILE"
      return 1
      ;;
    esac
    command tar "$@"
  }
  run_rollback
  grep -Fxq extract_failed "$TRACE_FILE" || fail_test "Extraction-failure fixture did not execute"
  assert_live_state_preserved
}

function outside_symlink_preserves_live_state() {
  local payload="$TMP_ROOT/unsafe-payload" outside="$TMP_ROOT/outside"
  local link_target="$1"
  begin_then_mutate
  mkdir -p "$payload/config" "$payload/certs" "$outside"
  printf 'outside-before\n' >"$outside/marker.txt"
  printf 'archive-config\n' >"$payload/config/marker.txt"
  ln -s "$link_target" "$payload/certs/escape.pem"
  (cd "$payload" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
    tar -czf "$PRE_CHANGE_BACKUP" config certs)
  _write_backup_archive_checksum "$PRE_CHANGE_BACKUP"
  run_rollback
  assert_file_value "$outside/marker.txt" outside-before
  [ ! -e "$CERTS_DIR/escape.pem" ] && [ ! -L "$CERTS_DIR/escape.pem" ] ||
    fail_test "Rollback installed an escaping symlink"
  assert_live_state_preserved
}

function absolute_symlink_preserves_live_state() {
  outside_symlink_preserves_live_state "$TMP_ROOT/outside/marker.txt"
}

function escaping_relative_symlink_preserves_live_state() {
  outside_symlink_preserves_live_state '../../outside/marker.txt'
}

function temporary_directory_target_round_trip() {
  printf 'temporary-before\n' >"$TMP_DIR/marker.txt"
  begin_transaction_return temporary_target "$CONFIG_DIR" "$TMP_DIR"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  printf 'temporary-current\n' >"$TMP_DIR/marker.txt"
  printf 'temporary-new\n' >"$TMP_DIR/new.txt"
  run_rollback
  assert_file_value "$CONFIG_DIR/marker.txt" before
  assert_file_value "$TMP_DIR/marker.txt" temporary-before
  [ ! -e "$TMP_DIR/new.txt" ] || fail_test "Rollback retained a new temporary file"
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "TMP_DIR rollback was not reported as complete"
}

function failing_recovery_hook() {
  printf 'failing_hook\n' >>"$TRACE_FILE"
  return 1
}

function later_recovery_hook() {
  printf 'later_hook\n' >>"$TRACE_FILE"
}

function hook_failure_is_reported() {
  begin_transaction_return hook_failure "$CONFIG_DIR"
  rollback_pre_hook_add failing_recovery_hook
  rollback_pre_hook_add later_recovery_hook
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  run_rollback
  assert_file_value "$CONFIG_DIR/marker.txt" before
  grep -Fxq failing_hook "$TRACE_FILE" || fail_test "Recovery failure hook did not execute"
  assert_rollback_incomplete
}

function replay_failure_restores_current_state() {
  local current_mtime=""
  mkdir "$CONFIG_DIR/readonly"
  printf 'readonly-before\n' >"$CONFIG_DIR/readonly/marker.txt"
  printf 'file-before\n' >"$CONFIG_DIR/replaced-file"
  chmod 550 "$CONFIG_DIR/readonly"
  # Put the newly created target before the injected failure, so undo must
  # recover both a replaced file and an already removed new target.
  begin_transaction_return replay_failure "$CONFIG_DIR" "$STATE_DIR/new-target" "$CERTS_DIR"
  chmod 700 "$CONFIG_DIR/readonly"
  rm -r "$CONFIG_DIR/readonly"
  printf 'readonly-current\n' >"$CONFIG_DIR/readonly"
  rm "$CONFIG_DIR/replaced-file"
  mkdir "$CONFIG_DIR/replaced-file"
  printf 'directory-current\n' >"$CONFIG_DIR/replaced-file/marker.txt"
  chmod 550 "$CONFIG_DIR/replaced-file"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  printf 'current-only\n' >"$CONFIG_DIR/current-only.txt"
  printf 'certificate-current\n' >"$CERTS_DIR/marker.pem"
  mkdir -p "$STATE_DIR/new-target"
  printf 'new-target-current\n' >"$STATE_DIR/new-target/marker.txt"
  chmod 750 "$CONFIG_DIR"
  touch -t 200202020202 "$CONFIG_DIR"
  current_mtime="$(file_mtime "$CONFIG_DIR")"
  function mv() {
    local replacement=false
    case "${1:-}" in */.dockistrate-rollback.*/new) replacement=true ;; esac
    if [ "$replacement" = true ] && [ "${2:-}" = "$CERTS_DIR/marker.pem" ]; then
      printf 'install_failed\n' >>"$TRACE_FILE"
      return 1
    fi
    command mv "$@" || return 1
    if [ "$replacement" = true ]; then
      printf 'installed %s\n' "$2" >>"$TRACE_FILE"
    elif [ "${1:-}" = "$STATE_DIR/new-target" ]; then
      printf 'new_target_displaced\n' >>"$TRACE_FILE"
    fi
  }
  run_rollback
  # This path is created by this rollback invocation, outside its state tree.
  # Register only its validated, unique workspace for test-owned cleanup.
  local retained=""
  retained="$(sed -n 's/^\[Error\] Retained validated rollback snapshot: //p' "$ROLLBACK_OUTPUT")"
  case "$retained" in
  /tmp/dockistrate_rollback.* | /private/tmp/dockistrate_rollback.*)
    [ -d "$retained" ] && [ ! -L "$retained" ] || fail_test "Recovery snapshot is missing"
    RETAINED_WORKSPACE="$retained"
    ;;
  *) fail_test "Failed replay did not identify its retained recovery snapshot" ;;
  esac
  grep -Fxq "installed $CONFIG_DIR/marker.txt" "$TRACE_FILE" || fail_test "Replay never restored the first file"
  grep -Fxq new_target_displaced "$TRACE_FILE" || fail_test "Replay never displaced the new target"
  grep -Fxq install_failed "$TRACE_FILE" || fail_test "Replay-failure fixture did not execute"
  assert_live_state_preserved
  assert_file_value "$CONFIG_DIR/readonly" readonly-current
  assert_file_value "$CONFIG_DIR/replaced-file/marker.txt" directory-current
  [ "$(file_mode "$CONFIG_DIR/replaced-file")" = 550 ] || fail_test "Undo lost the displaced directory mode"
  [ "$(file_mode "$CONFIG_DIR")" = 750 ] || fail_test "Replay undo changed the current directory mode"
  [ "$(file_mtime "$CONFIG_DIR")" = "$current_mtime" ] || fail_test "Replay undo changed the current directory timestamp"
  assert_file_value "$RETAINED_WORKSPACE/extracted/config/marker.txt" before
  assert_file_value "$RETAINED_WORKSPACE/extracted/certs/marker.pem" certificate-before
  grep -Fq 'state present before replay was restored' "$ROLLBACK_OUTPUT" ||
    fail_test "Replay recovery did not describe the restored current state"
  if grep -Fxq load_config "$TRACE_FILE"; then
    fail_test "Failed file recovery reloaded configuration"
  fi
  [ -z "$(find "$STATE_DIR" -name '.dockistrate-rollback.*' -print)" ] ||
    fail_test "Successful undo left sibling recovery slots behind"
}

function missing_original_target_preserves_live_state() {
  local payload="$TMP_ROOT/incomplete-payload"
  begin_then_mutate
  mkdir -p "$payload/config"
  printf 'archive-config\n' >"$payload/config/marker.txt"
  # This is a valid, checksum-matched archive, but certificates existed when
  # the transaction began and their entire target is missing from the archive.
  (cd "$payload" && tar -czf "$PRE_CHANGE_BACKUP" config)
  _write_backup_archive_checksum "$PRE_CHANGE_BACKUP"
  run_rollback
  assert_live_state_preserved
  grep -Fq "missing target: $CERTS_DIR" "$ROLLBACK_OUTPUT" ||
    fail_test "Rollback did not identify the omitted original target"
}

function overlapping_targets_preserve_nested_inodes() {
  local nested="$CONFIG_DIR/nested" leaf="$CONFIG_DIR/nested/leaf"
  local config_inode="" nested_inode="" leaf_inode=""
  mkdir -p "$leaf"
  printf 'nested-before\n' >"$nested/marker.txt"
  printf 'leaf-before\n' >"$leaf/marker.txt"
  config_inode="$(file_inode "$CONFIG_DIR")"
  nested_inode="$(file_inode "$nested")"
  leaf_inode="$(file_inode "$leaf")"
  # A child before its parent must not create duplicate tar members, nor cause
  # repeated replay to replace directory inodes used by Docker bind mounts.
  begin_transaction_return overlapping "$leaf/marker.txt" "$nested" "$CONFIG_DIR"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  printf 'nested-current\n' >"$nested/marker.txt"
  printf 'leaf-current\n' >"$leaf/marker.txt"
  printf 'new\n' >"$leaf/new.txt"
  run_rollback
  assert_file_value "$CONFIG_DIR/marker.txt" before
  assert_file_value "$nested/marker.txt" nested-before
  assert_file_value "$leaf/marker.txt" leaf-before
  [ ! -e "$leaf/new.txt" ] || fail_test "Nested rollback retained a new file"
  [ "$(file_inode "$CONFIG_DIR")" = "$config_inode" ] || fail_test "Rollback replaced the config directory inode"
  [ "$(file_inode "$nested")" = "$nested_inode" ] || fail_test "Rollback replaced a nested directory inode"
  [ "$(file_inode "$leaf")" = "$leaf_inode" ] || fail_test "Rollback replaced the deepest directory inode"
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "Overlapping-target rollback was incomplete"
}

function exit_mode_failure_does_not_reenter() {
  local status=0 captures=0
  function capture_docker_logs() {
    printf 'capture\n' >>"$TRACE_FILE"
    # Bound a regressed ERR/EXIT recursion without hiding its repeated entry.
    if [ "$(grep -Fxc capture "$TRACE_FILE")" -gt 2 ]; then
      trap - ERR EXIT
      exit 99
    fi
  }
  # Do not use an if/|| context here: the child must exercise a real ERR trap.
  set +e
  (
    set -e
    begin_transaction exit_trap_failure "$CONFIG_DIR" "$CERTS_DIR"
    printf 'current\n' >"$CONFIG_DIR/marker.txt"
    printf 'certificate-current\n' >"$CERTS_DIR/marker.pem"
    printf 'checksum-mismatch\n' >>"$PRE_CHANGE_BACKUP"
    false
    printf 'continued\n' >"$TMP_ROOT/after-error.txt"
  ) >"$ROLLBACK_OUTPUT" 2>&1
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail_test "Exit-mode failure returned unexpected status $status"
  captures="$(grep -Fxc capture "$TRACE_FILE" || true)"
  [ "$captures" -eq 1 ] || fail_test "Exit-mode rollback entered $captures times"
  [ ! -e "$TMP_ROOT/after-error.txt" ] || fail_test "Exit-mode failure continued the original operation"
  [ ! -e "$TMP_DIR/.dockistrate_transaction.lock" ] || fail_test "Exit-mode failure retained the transaction lock"
  assert_file_value "$CONFIG_DIR/marker.txt" current
  assert_file_value "$CERTS_DIR/marker.pem" certificate-current
  assert_rollback_incomplete
}

function absent_nested_target_remains_absent() {
  local missing_parent="$STATE_DIR/not-created"
  mkdir -p "$missing_parent"
  begin_transaction_return absent_target "$missing_parent/leaf"
  rmdir "$missing_parent"
  run_rollback
  [ ! -e "$missing_parent" ] && [ ! -L "$missing_parent" ] ||
    fail_test "Rollback created a parent for an untouched missing target"
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "Absent-target rollback was incomplete"
}

function never_created_nested_target_remains_absent() {
  local missing_root="$STATE_DIR/domains" target="$STATE_DIR/domains/new.example.com/runtime"
  begin_transaction_return absent_new_domain "$CONFIG_DIR" "$target"
  printf 'partial change\n' >"$CONFIG_DIR/marker.txt"
  run_rollback
  [ ! -e "$missing_root" ] && [ ! -L "$missing_root" ] ||
    fail_test "Rollback created parents for a domain that was never written"
  assert_file_value "$CONFIG_DIR/marker.txt" before
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "Never-created domain rollback was incomplete"
}

function recovery_hook_sees_reloaded_config() {
  local runtime_option=before
  function load_config() {
    printf 'load_config\n' >>"$TRACE_FILE"
    runtime_option=before
  }
  function verify_reloaded_config() {
    printf 'verify_reloaded_config\n' >>"$TRACE_FILE"
    [ "$runtime_option" = before ]
  }
  begin_transaction_return reload_before_hook "$CONFIG_DIR"
  rollback_pre_hook_add verify_reloaded_config
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  runtime_option=current
  run_rollback
  assert_file_value "$CONFIG_DIR/marker.txt" before
  grep -Fxq verify_reloaded_config "$TRACE_FILE" || fail_test "Recovery hook did not execute"
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "Recovery hook did not see restored configuration"
}

function failed_config_reload_skips_recovery_hook() {
  function load_config() {
    printf 'load_config_failed\n' >>"$TRACE_FILE"
    return 1
  }
  function unexpected_runtime_recovery() {
    printf 'unexpected_runtime_recovery\n' >>"$TRACE_FILE"
  }
  begin_transaction_return failed_reload "$CONFIG_DIR"
  rollback_pre_hook_add unexpected_runtime_recovery
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  run_rollback
  assert_file_value "$CONFIG_DIR/marker.txt" before
  grep -Fxq load_config_failed "$TRACE_FILE" || fail_test "Failed reload fixture did not execute"
  if grep -Fxq unexpected_runtime_recovery "$TRACE_FILE"; then
    fail_test "Recovery hook executed after configuration reload failed"
  fi
  assert_rollback_incomplete
}

function aliased_missing_target_is_removed() {
  local state_alias="$TMP_ROOT/state-alias"
  ln -s "$STATE_DIR" "$state_alias"
  if _rollback_replay_normalize_target "$state_alias/not-created/../../outside" >/dev/null 2>&1; then
    fail_test "Missing-parent normalization accepted unresolved traversal through a state alias"
  fi
  begin_transaction_return aliased_target "$state_alias/new-target"
  mkdir -p "$state_alias/new-target"
  printf 'new\n' >"$state_alias/new-target/marker.txt"
  run_rollback
  [ ! -e "$STATE_DIR/new-target" ] && [ ! -L "$STATE_DIR/new-target" ] ||
    fail_test "Rollback retained a new target addressed through a parent alias"
  [ -L "$state_alias" ] || fail_test "Rollback changed the parent alias"
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "Aliased-target rollback was incomplete"
}

function directory_metadata_round_trip() {
  local nested="$CONFIG_DIR/nested" config_inode="" nested_inode="" before_mtime=""
  mkdir "$nested"
  printf 'nested-before\n' >"$nested/marker.txt"
  chmod 640 "$CONFIG_DIR/marker.txt"
  chmod 640 "$CERTS_DIR/marker.pem"
  chmod 2750 "$CONFIG_DIR"
  chmod 550 "$nested"
  touch -t 200001010101 "$CONFIG_DIR" "$nested"
  before_mtime="$(file_mtime "$CONFIG_DIR")"
  config_inode="$(file_inode "$CONFIG_DIR")"
  nested_inode="$(file_inode "$nested")"
  begin_transaction_return directory_metadata "$CONFIG_DIR" "$CERTS_DIR"
  chmod 700 "$CONFIG_DIR" "$nested"
  chmod g-s "$CONFIG_DIR"
  chmod g+s "$nested"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  printf 'nested-current\n' >"$nested/marker.txt"
  printf 'new\n' >"$nested/new.txt"
  chmod 600 "$CONFIG_DIR/marker.txt" "$CERTS_DIR/marker.pem"
  touch -t 200202020202 "$CONFIG_DIR" "$nested"
  run_rollback
  assert_file_value "$CONFIG_DIR/marker.txt" before
  assert_file_value "$nested/marker.txt" nested-before
  [ ! -e "$nested/new.txt" ] || fail_test "Directory rollback retained a new file"
  [ "$(file_mode "$CONFIG_DIR/marker.txt")" = 640 ] || fail_test "Rollback lost config file group permissions"
  [ "$(file_mode "$CERTS_DIR/marker.pem")" = 640 ] || fail_test "Rollback lost certificate group permissions"
  [ "$(file_mode "$CONFIG_DIR")" = 2750 ] || fail_test "Rollback lost the original directory mode, including setgid"
  [ "$(file_mode "$nested")" = 550 ] || fail_test "Rollback lost the original read-only directory mode"
  [ "$(file_mtime "$CONFIG_DIR")" = "$before_mtime" ] || fail_test "Rollback lost the original directory timestamp"
  [ "$(file_mtime "$nested")" = "$before_mtime" ] || fail_test "Rollback cleanup changed the nested directory timestamp"
  [ "$(file_inode "$CONFIG_DIR")" = "$config_inode" ] || fail_test "Metadata restore replaced a directory inode"
  [ "$(file_inode "$nested")" = "$nested_inode" ] || fail_test "Metadata restore replaced a nested directory inode"
  [ -z "$(find "$STATE_DIR" -name '.dockistrate-rollback.*' -print)" ] || fail_test "Read-only metadata left recovery slots behind"
  grep -Fq 'Rolled back.' "$ROLLBACK_OUTPUT" || fail_test "Directory metadata rollback was incomplete"
}

function directory_metadata_bsd_stat_round_trip() {
  # Native BSD stat is already covered by the ordinary round trip. On GNU,
  # emulate its full-mode %p and permission-only %Lp formats so losing the
  # special bits is caught before macOS CI runs.
  if ! command stat -c '%a' "$CONFIG_DIR" >/dev/null 2>&1; then
    return 0
  fi
  function stat() {
    local raw_mode=""
    if [ "${1:-}" = -c ] && [ "${2:-}" = '%a' ]; then
      return 1
    fi
    if [ "${1:-}" = -f ]; then
      case "${2:-}" in
      '%p')
        raw_mode="$(command stat -c '%f' "$3")" || return 1
        printf '%o\n' "$((16#$raw_mode))"
        return 0
        ;;
      '%Lp')
        raw_mode="$(command stat -c '%a' "$3")" || return 1
        printf '%o\n' "$((8#$raw_mode & 0777))"
        return 0
        ;;
      esac
    fi
    command stat "$@"
  }
  directory_metadata_round_trip
}

function directory_metadata_failure_restores_current_state() {
  local injected=false current_mtime="" retained="" metadata_failure_status="${1:-1}"
  chmod 750 "$CERTS_DIR"
  begin_then_mutate
  chmod 700 "$CONFIG_DIR" "$CERTS_DIR"
  touch -t 200202020202 "$CONFIG_DIR" "$CERTS_DIR"
  current_mtime="$(file_mtime "$CONFIG_DIR")"
  function chmod() {
    if [ "${injected:-true}" = false ] && [ "${1:-}" = 00750 ] && [ "${2:-}" = "$CERTS_DIR" ]; then
      injected=true
      printf 'metadata_failed\n' >>"$TRACE_FILE"
      return "$metadata_failure_status"
    fi
    command chmod "$@"
  }
  run_rollback
  retained="$(sed -n 's/^\[Error\] Retained validated rollback snapshot: //p' "$ROLLBACK_OUTPUT")"
  case "$retained" in
  /tmp/dockistrate_rollback.* | /private/tmp/dockistrate_rollback.*)
    [ -d "$retained" ] && [ ! -L "$retained" ] || fail_test "Metadata failure lost its recovery snapshot"
    RETAINED_WORKSPACE="$retained"
    ;;
  *) fail_test "Metadata failure did not retain its recovery snapshot" ;;
  esac
  grep -Fxq metadata_failed "$TRACE_FILE" || fail_test "Metadata failure fixture did not execute"
  assert_live_state_preserved
  [ "$(file_mode "$CONFIG_DIR")" = 700 ] && [ "$(file_mode "$CERTS_DIR")" = 700 ] ||
    fail_test "Metadata failure did not restore the current directory modes"
  [ "$(file_mtime "$CONFIG_DIR")" = "$current_mtime" ] && [ "$(file_mtime "$CERTS_DIR")" = "$current_mtime" ] ||
    fail_test "Metadata failure did not restore the current directory timestamps"
  [ -z "$(find "$STATE_DIR" -name '.dockistrate-rollback.*' -print)" ] || fail_test "Metadata undo left recovery slots behind"
  grep -Fq 'state present before replay was restored' "$ROLLBACK_OUTPUT" || fail_test "Metadata failure did not report successful undo"
}

function directory_metadata_silent_failure_restores_current_state() {
  # A successful chmod status alone does not prove the requested mode applied.
  directory_metadata_failure_restores_current_state 0
}

function staging_group_failure_preserves_live_state() {
  local failed_workspace=""
  begin_then_mutate
  function chgrp() {
    failed_workspace="${2:-}"
    return 1
  }
  run_rollback
  assert_live_state_preserved
  [ -n "$failed_workspace" ] || fail_test "Staging group failure fixture did not execute"
  [ ! -e "$failed_workspace" ] && [ ! -L "$failed_workspace" ] ||
    fail_test "Failed staging group preparation leaked its workspace"
  grep -Fq 'Failed to prepare the rollback staging group' "$ROLLBACK_OUTPUT" ||
    fail_test "Staging group failure was not explained"
}

"$2"
