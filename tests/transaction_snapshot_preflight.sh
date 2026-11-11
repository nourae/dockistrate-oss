#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES=(
  state_root_begin_rejected
  state_root_backup_rejected
  leaf_symlink_targets_rejected
  aliased_duplicate_targets_round_trip
  aliased_parent_child_targets_round_trip
  direct_backup_deduplicates_targets
  retained_snapshot_survives_same_second_retry
  snapshot_names_remain_compatible
  archive_reservation_collision_preserves_previous
)

if [ "$#" -eq 0 ]; then
  failed=0
  for test_case in "${CASES[@]}"; do
    if "$BASH" "${BASH_SOURCE[0]}" --case "$test_case"; then
      printf '[tests] PASS: transaction snapshot %s\n' "$test_case"
    else
      printf '[tests] FAIL: transaction snapshot %s\n' "$test_case" >&2
      failed=1
    fi
  done
  exit "$failed"
fi
[ "$#" -eq 2 ] && [ "$1" = --case ] || exit 2
case_found=false
for test_case in "${CASES[@]}"; do
  [ "$test_case" != "$2" ] || case_found=true
done
[ "$case_found" = true ] || exit 2

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_snapshot_preflight.XXXXXX")")"
function cleanup() { rm -rf "$TMP_ROOT"; }
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
ENABLE_AUTO_BACKUPS=true
ENABLE_BACKUP_COMPRESSION=true
BACKUP_RETENTION=0
SKIP_DOCKER_CHECKS=true
NGINX_CONTAINER_NAME=snapshot-test-nginx
OUTPUT="$TMP_ROOT/result.log"
mkdir -p "$CONFIG_DIR/nested" "$CERTS_DIR" "$TMP_DIR" "$ERROR_LOG_DIR" \
  "$BACKUP_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR"
printf 'before\n' >"$CONFIG_DIR/marker.txt"
printf 'nested-before\n' >"$CONFIG_DIR/nested/marker.txt"
STATE_ALIAS="$TMP_ROOT/state-alias"
ln -s "$STATE_DIR" "$STATE_ALIAS"

function log_msg() { :; }
function capture_docker_logs() { :; }
function load_config() { :; }
function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function assert_value() {
  [ -f "$1" ] && [ "$(cat "$1")" = "$2" ] || fail_test "Unexpected contents: $1"
}
function assert_no_transaction() {
  if transaction_is_active || [ -n "${PRE_CHANGE_BACKUP:-}" ] || [ -n "${ROLLBACK_DESC:-}" ]; then
    fail_test 'Rejected snapshot left transaction state active'
  fi
  [ ! -e "$(_transaction_lock_dir)" ] || fail_test 'Rejected snapshot retained its lock'
}
function assert_no_archives() {
  [ -z "$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -print)" ] ||
    fail_test 'Rejected snapshot created a backup artifact'
}
function rollback_successfully() {
  if _rollback_handler_return >"$OUTPUT" 2>&1; then
    fail_test 'Return-mode rollback reported operation success'
  fi
  grep -Fq 'Rolled back.' "$OUTPUT" || fail_test 'Snapshot could not be replayed'
  assert_no_transaction
}

function state_root_begin_rejected() {
  local target=""
  # Keep the archive destination out of this fixture's selected root so the
  # old writer cannot reject the operation merely because tar sees itself.
  BACKUP_DIR="$TMP_ROOT/separate-backups"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  mkdir -p "$BACKUP_DIR"
  for target in "$STATE_DIR" "$STATE_DIR/." "$STATE_ALIAS/."; do
    if begin_transaction_return root_target "$target" >"$OUTPUT" 2>&1; then
      printf 'caller-mutated\n' >"$CONFIG_DIR/marker.txt"
      fail_test 'Transaction accepted the state root and allowed the caller to mutate it'
    fi
    grep -Fq 'state root itself' "$OUTPUT" || fail_test 'State-root rejection was not explicit'
    assert_value "$CONFIG_DIR/marker.txt" before
    assert_no_transaction
    assert_no_archives
  done
}

function state_root_backup_rejected() {
  local old_umask=""
  old_umask="$(umask)"
  BACKUP_DIR="$TMP_ROOT/separate-backups"
  mkdir -p "$BACKUP_DIR"
  if backup_files_only root_target "$STATE_DIR/." >"$OUTPUT" 2>&1; then
    fail_test 'Direct snapshot writer accepted the state root'
  fi
  grep -Fq 'state root itself' "$OUTPUT" || fail_test 'Direct state-root rejection was not explicit'
  [ "$(umask)" = "$old_umask" ] || fail_test 'Rejected root snapshot changed umask'
  assert_no_archives
}

function leaf_symlink_targets_rejected() {
  local link="$STATE_DIR/linked-config" target=""
  ln -s "$CONFIG_DIR" "$link"
  for target in "$link" "$link/"; do
    if begin_transaction_return linked_leaf "$target" >"$OUTPUT" 2>&1; then
      fail_test 'Normalization bypassed the symlink-leaf guard'
    fi
    assert_no_transaction
    assert_no_archives
  done
  [ -L "$link" ] || fail_test 'Rejected snapshot changed the symlink'
  assert_value "$link/marker.txt" before
}

function aliased_duplicate_targets_round_trip() {
  cd "$TMP_ROOT"
  CDPATH="$TMP_ROOT/nonexistent"
  begin_transaction_return alias_duplicate state/config "$STATE_ALIAS/config"
  [ "${#ROLLBACK_FILES[@]}" -eq 1 ] || fail_test 'Physical duplicate targets were not collapsed'
  [ "${ROLLBACK_FILES[0]}" = "$CONFIG_DIR" ] || fail_test 'Rollback target is not physical'
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  rollback_successfully
  assert_value "$CONFIG_DIR/marker.txt" before
}

function aliased_parent_child_targets_round_trip() {
  begin_transaction_return alias_overlap "$STATE_ALIAS/config/nested/marker.txt" \
    "$CONFIG_DIR/nested" "$STATE_ALIAS/config/./" "$CONFIG_DIR/new-file"
  [ "${#ROLLBACK_FILES[@]}" -eq 1 ] || fail_test 'Physical parent/child targets were not collapsed'
  printf 'current\n' >"$CONFIG_DIR/nested/marker.txt"
  printf 'new\n' >"$CONFIG_DIR/new-file"
  rollback_successfully
  assert_value "$CONFIG_DIR/nested/marker.txt" nested-before
  [ ! -e "$CONFIG_DIR/new-file" ] || fail_test 'Rollback retained a new nested target'
}

function direct_backup_deduplicates_targets() {
  local archive=""
  archive="$(backup_files_only pre_direct "$STATE_ALIAS/config/nested/marker.txt" \
    "$CONFIG_DIR" "$STATE_ALIAS/config" "$CONFIG_DIR/nested")"
  begin_transaction_return direct_replay "$CONFIG_DIR"
  PRE_CHANGE_BACKUP="$archive"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  printf 'nested-current\n' >"$CONFIG_DIR/nested/marker.txt"
  rollback_successfully
  assert_value "$CONFIG_DIR/marker.txt" before
  assert_value "$CONFIG_DIR/nested/marker.txt" nested-before
}

function freeze_backup_clock() {
  function date() {
    if [ "${1:-}" = '+%Y%m%d_%H%M%S' ]; then
      printf '20260101_010101\n'
    else
      command date "$@"
    fi
  }
}

function retained_snapshot_survives_same_second_retry() {
  local retained="" retry=""
  freeze_backup_clock
  begin_transaction_return same_second "$CONFIG_DIR"
  retained="$PRE_CHANGE_BACKUP"
  cp "$retained" "$TMP_ROOT/retained.tar.gz"
  cp "$retained.sha256" "$TMP_ROOT/retained.sha256"
  printf 'current\n' >"$CONFIG_DIR/marker.txt"
  function tar() {
    case "${1:-}" in -xzf | -xozf) return 1 ;; esac
    command tar "$@"
  }
  if _rollback_handler_return >"$OUTPUT" 2>&1; then
    fail_test 'Failed recovery reported operation success'
  fi
  unset -f tar
  if grep -Fq 'Rolled back.' "$OUTPUT"; then fail_test 'Injected extraction failure was ignored'; fi
  assert_no_transaction
  assert_value "$CONFIG_DIR/marker.txt" current
  begin_transaction_return same_second "$CONFIG_DIR"
  retry="$PRE_CHANGE_BACKUP"
  [ "$retry" != "$retained" ] || fail_test 'Same-second retry reused the retained snapshot pathname'
  cmp -s "$retained" "$TMP_ROOT/retained.tar.gz" || fail_test 'Retry overwrote retained archive bytes'
  cmp -s "$retained.sha256" "$TMP_ROOT/retained.sha256" || fail_test 'Retry overwrote retained checksum'
  _verify_backup_archive_checksum_if_present "$retained" || fail_test 'Retained checksum no longer verifies'
  printf 'retry-mutated\n' >"$CONFIG_DIR/marker.txt"
  rollback_successfully
  assert_value "$CONFIG_DIR/marker.txt" current
  [ "$(tar -xOzf "$retained" config/marker.txt)" = before ] || fail_test 'Original recovery state was lost'
}

function snapshot_names_remain_compatible() {
  local first="" second="" listed="" archive=""
  freeze_backup_clock
  first="$(backup_files_only pre_compatible "$CONFIG_DIR")"
  second="$(backup_files_only pre_compatible "$CONFIG_DIR")"
  [ "$first" != "$second" ] || fail_test 'Repeated backups share a pathname'
  for archive in "$first" "$second"; do
    is_valid_backup_name "${archive##*/}" || fail_test 'Snapshot name is not valid for backup helpers'
    is_transaction_backup_archive "$archive" || fail_test 'Snapshot is not recognized as a transaction backup'
    case "${archive##*/}" in 20260101_010101_pre_compatible_*.tar.gz) ;; *) fail_test 'Snapshot lost its compatible name shape' ;; esac
    [ -f "$archive.sha256" ] || fail_test 'Snapshot lost its checksum sidecar'
  done
  listed="$(list_backups)"
  for archive in "$first" "$second"; do
    printf '%s\n' "$listed" | grep -Fxq "${archive##*/}" || fail_test 'Snapshot is missing from list-backups'
  done
}

function archive_reservation_collision_preserves_previous() {
  local collision_archive="$BACKUP_DIR/20260101_010101_pre_collision_ABCDEF.tar.gz"
  local old_umask=""
  old_umask="$(umask)"
  freeze_backup_clock
  printf 'retained archive\n' >"$collision_archive"
  printf 'retained checksum\n' >"$collision_archive.sha256"
  function mktemp() {
    case "${1:-}" in
    "$BACKUP_DIR/20260101_010101_pre_collision_"*)
      : >"${collision_archive%.tar.gz}"
      printf '%s\n' "${collision_archive%.tar.gz}"
      ;;
    *) command mktemp "$@" ;;
    esac
  }
  if backup_files_only pre_collision "$CONFIG_DIR" >"$OUTPUT" 2>&1; then
    fail_test 'Archive reservation collision did not fail closed'
  fi
  assert_value "$collision_archive" 'retained archive'
  assert_value "$collision_archive.sha256" 'retained checksum'
  [ ! -e "${collision_archive%.tar.gz}" ] || fail_test 'Failed reservation left its temporary file'
  [ "$(umask)" = "$old_umask" ] || fail_test 'Failed reservation changed umask'
}

"$2"
