#!/usr/bin/env bash
set -Eeuo pipefail
# Ordinary restore copies must retain the fixture's 0644 key so the injected
# chmod failure is exercised regardless of the invoking operator's umask.
umask 022

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Real backup, transaction, rollback, and permission repair implementations.
# Only Docker/config rendering and operator confirmation are replaced here.
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/permissions.sh
source "$ROOT_DIR/lib/permissions.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-key-restore.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
FAIL_CHMOD_TARGET=""

function confirm_prompt() { return 0; }
function capture_docker_logs() { :; }
function log_msg() { :; }
function update_nginx_config() { :; }
function _nginx_image_runs_as_root() { return 0; }
function docker() { echo '[Error] Permission restore fixture must not invoke Docker.' >&2; return 99; }
function chmod() {
  local arg=""
  for arg in "$@"; do
    if [ -n "$FAIL_CHMOD_TARGET" ] && [ "$arg" = "$FAIL_CHMOD_TARGET" ]; then
      return 1
    fi
  done
  command chmod "$@"
}

# Preserve the failed-repair/outer-content-rollback regression now that the
# metadata journal uses a descriptor helper instead of a pathname utility.
eval "$(declare -f _permissions_metadata_mutate_fd | sed '1s/_permissions_metadata_mutate_fd/_test_real_metadata_mutate_fd/')"
function _permissions_metadata_mutate_fd() {
  if [ "$2" = chmod ] && [ -n "$FAIL_CHMOD_TARGET" ] && [ "${PERMISSIONS_TXN_PATHS[$1]}" = "$FAIL_CHMOD_TARGET" ]; then
    return 1
  fi
  _test_real_metadata_mutate_fd "$@"
}

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$TEST_DIR/output" ] || cat "$TEST_DIR/output" >&2
  exit 1
}

function mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

function reset_fixture() {
  BASE_DIR="$TEST_DIR/$1"
  STATE_DIR="$BASE_DIR/state"
  CONFIG_DIR="$STATE_DIR/config"
  CERTS_DIR="$STATE_DIR/certs"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
  NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
  NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
  BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
  CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
  INTERACTIVE_RECENT_FILE="$CONFIG_DIR/interactive_recent.csv"
  INTERACTIVE_FAVORITES_FILE="$CONFIG_DIR/interactive_favorites.csv"
  LOG_FILE="$LOG_DIR/docker_manager.log"
  AUDIT_LOG_FILE="$LOG_DIR/audit.log"
  SKIP_DOCKER_CHECKS=true
  ENABLE_AUTO_BACKUPS=true
  ENABLE_BACKUP_COMPRESSION=true
  BACKUP_RETENTION=0
  mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR"
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '%s\n' original >"$CONFIG_DIR/marker.txt"
  printf '%s\n' DUMMY_ORIGINAL_KEY >"$CONFIG_DIR/original.key"
  command chmod 400 "$CONFIG_DIR/original.key"
  BACKUP_SOURCE="$BASE_DIR/restore-source"
  mkdir -p "$BACKUP_SOURCE/config"
  cp "$GLOBAL_SETTINGS_FILE" "$BACKUP_SOURCE/config/global_settings.csv"
  printf '%s\n' restored >"$BACKUP_SOURCE/config/marker.txt"
  printf '%s\n' DUMMY_RESTORED_KEY >"$BACKUP_SOURCE/config/restored.key"
  command chmod 644 "$BACKUP_SOURCE/config/restored.key"
  FAIL_CHMOD_TARGET=""
}

function test_bsd_stat_inside_transaction() {
  local helper="$1" observed="" before_traps="" before_backup="" real_stat="" fixture_mode=""
  reset_fixture "bsd-stat-$helper"
  real_stat="$(type -P stat)"
  [ -n "$real_stat" ] || fail_test 'external stat is required for BSD probe coverage'
  command chmod 600 "$CONFIG_DIR/marker.txt"
  begin_transaction "bsd_stat_${helper}" "$CONFIG_DIR"
  before_traps="$(trap -p ERR EXIT)"
  before_backup="$PRE_CHANGE_BACKUP"
  printf '%s\n' changed >"$CONFIG_DIR/marker.txt"
  # BSD %Lp omits special bits; require the full %p result in this fallback.
  command chgrp "$(id -g)" "$CONFIG_DIR/marker.txt"
  command chmod 6600 "$CONFIG_DIR/marker.txt"
  if fixture_mode="$("$real_stat" -c '%f' "$CONFIG_DIR/marker.txt" 2>/dev/null || exit 1)"; then
    fixture_mode=$((16#$fixture_mode & 07777))
  else
    fixture_mode="$("$real_stat" -f '%p' "$CONFIG_DIR/marker.txt" || exit 1)"
    fixture_mode=$((8#$fixture_mode & 07777))
  fi
  [ "$fixture_mode" -eq "$((8#6600))" ] || fail_test 'BSD stat fixture did not retain its requested special bits'
  STAT_BSD_FAIL=false

  # Simulate BSD stat for the inspected operation on every host. A failed GNU
  # probe can emit stdout; fallback must discard it without invoking rollback.
  # Later recovery probes use the real tool so a negative control can replay
  # its actual archive without the failure injection corrupting that recovery.
  # Bash 3 can run inherited ERR traps for `command stat` even in an OR list;
  # use the resolved executable so this fixture does not add that separate bug.
  function stat() {
    local format="${2:-}" path="" raw="" device="" inode="" uid="" gid="" mode="" links=""
    case "${1:-}:$format" in
    '-c:%a' | '-c:%d %i %u %g %a %h')
      if [ -e "$TEST_DIR/stat-gnu-probe-seen" ] && [ "$STAT_BSD_FAIL" != true ]; then
        "$real_stat" "$@" || return 1
        return 0
      fi
      : >"$TEST_DIR/stat-gnu-probe-seen"
      printf '%s\n' 'failed GNU probe output'
      return 1
      ;;
    '-f:%p' | '-f:%d %i %u %g %p %l')
      if [ "$STAT_BSD_FAIL" = true ]; then
        printf '%s\n' 'failed BSD probe output'
        return 1
      fi
      shift 2
      for path in "$@"; do
        case "$format" in
        '%p')
          if raw="$("$real_stat" -c '%f' "$path" 2>/dev/null || exit 1)"; then
            printf '%o\n' "$((16#$raw))"
          else
            "$real_stat" -f '%p' "$path" || return 1
          fi
          ;;
        *)
          if raw="$("$real_stat" -c '%d %i %u %g %f %h' "$path" 2>/dev/null || exit 1)"; then
            read -r device inode uid gid mode links <<<"$raw"
            printf '%s %s %s %s %o %s\n' "$device" "$inode" "$uid" "$gid" "$((16#$mode))" "$links"
          else
            "$real_stat" -f '%d %i %u %g %p %l' "$path" || return 1
          fi
          ;;
        esac
      done
      ;;
    *) "$real_stat" "$@" || return 1 ;;
    esac
  }

  case "$helper" in
  mode)
    observed="$(_portable_stat_mode "$CONFIG_DIR/marker.txt")"
    [ "$observed" = 6600 ] || fail_test 'BSD mode fallback lost special bits or returned failed probe output'
    ;;
  metadata)
    _permissions_metadata_stat "$CONFIG_DIR/marker.txt"
    [ "$PERMISSIONS_STAT_MODE" = 6600 ] || fail_test 'BSD metadata fallback lost special bits or returned failed probe output'
    ;;
  esac
  [ "$(cat "$CONFIG_DIR/marker.txt")" = changed ] || fail_test "$helper stat fallback rolled back an active transaction"
  [ "$(trap -p ERR EXIT)" = "$before_traps" ] || fail_test "$helper stat fallback replaced transaction traps"
  [ "$PRE_CHANGE_BACKUP" = "$before_backup" ] || fail_test "$helper stat fallback replaced the transaction backup"
  [ -d "$(_transaction_lock_dir)" ] || fail_test "$helper stat fallback released the transaction lock"

  STAT_BSD_FAIL=true
  case "$helper" in
  mode)
    # This is an intentionally handled helper failure. Bash 3 needs the guard
    # inside the substitution as well as the surrounding conditional.
    if observed="$(_portable_stat_mode "$CONFIG_DIR/marker.txt" || exit 1)"; then
      fail_test 'mode inspection accepted failure of both stat probes'
    fi
    ;;
  metadata)
    if _permissions_metadata_stat "$CONFIG_DIR/marker.txt"; then
      fail_test 'metadata inspection accepted failure of both stat probes'
    fi
    ;;
  esac
  [ "$(cat "$CONFIG_DIR/marker.txt")" = changed ] || fail_test "$helper handled stat failure unexpectedly rolled back content"
  unset -f stat
  end_transaction_success
  [ "$(cat "$CONFIG_DIR/marker.txt")" = changed ] || fail_test "$helper transaction lost content at completion"
}

function test_inherited_permission_transaction_state() {
  local operation="$1" before_depth="" before_backup="" before_traps=""
  reset_fixture "ambient-permission-state-$operation"
  case "$operation" in
  success | nested-repair)
    begin_transaction "ambient_permission_${operation}" "$CONFIG_DIR"
    printf '%s\n' changed >"$CONFIG_DIR/marker.txt"
    if [ "$operation" = nested-repair ]; then
      before_depth="$TRANSACTION_DEPTH"
      before_backup="$PRE_CHANGE_BACKUP"
      before_traps="$(trap -p ERR EXIT)"
      fix_permissions "$CONFIG_DIR"
      [ "$TRANSACTION_DEPTH" = "$before_depth" ] || fail_test 'inherited permission state changed outer transaction depth'
      [ "$PRE_CHANGE_BACKUP" = "$before_backup" ] || fail_test 'inherited permission state replaced outer content backup'
      [ "$(trap -p ERR EXIT)" = "$before_traps" ] || fail_test 'inherited permission state replaced outer transaction traps'
      transaction_is_active || fail_test 'nested repair ended its outer content transaction'
    fi
    end_transaction_success
    [ "$(cat "$CONFIG_DIR/marker.txt")" = changed ] || fail_test 'ambient permission state prevented ordinary transaction completion'
    [ -s "$LAST_POST_BACKUP_FILE" ] || fail_test 'ordinary completion skipped its post-change backup pointer'
    [ -f "$(cat "$LAST_POST_BACKUP_FILE")" ] || fail_test 'ordinary completion did not retain its real post-change archive'
    [ -z "${PRE_CHANGE_BACKUP:-}" ] || fail_test 'ordinary completion retained an active pre-change snapshot'
    ;;
  rollback)
    if (
      begin_transaction ambient_permission_rollback "$CONFIG_DIR"
      printf '%s\n' changed >"$CONFIG_DIR/marker.txt"
      _rollback_handler
    ) >"$TEST_DIR/rollback-output" 2>&1; then
      fail_test 'ordinary rollback reported success with inherited permission state'
    fi
    [ "$(cat "$CONFIG_DIR/marker.txt")" = original ] || fail_test 'ambient permission state bypassed ordinary content rollback'
    grep -q 'ambient_permission_rollback failed. Rolled back.' "$TEST_DIR/rollback-output" || fail_test 'ordinary rollback did not report real archive recovery'
    ;;
  return-rollback)
    begin_transaction_return ambient_permission_return_rollback "$CONFIG_DIR"
    printf '%s\n' changed >"$CONFIG_DIR/marker.txt"
    if _rollback_handler_return >"$TEST_DIR/rollback-output" 2>&1; then
      fail_test 'return-mode rollback reported success with inherited permission state'
    fi
    [ "$(cat "$CONFIG_DIR/marker.txt")" = original ] || fail_test 'ambient permission state bypassed return-mode content rollback'
    grep -q 'ambient_permission_return_rollback failed. Rolled back.' "$TEST_DIR/rollback-output" || fail_test 'return-mode rollback did not report real archive recovery'
    ;;
  *) fail_test "unknown ambient permission-state fixture: $operation" ;;
  esac
  if transaction_is_active; then
    fail_test 'ordinary transaction remained active with inherited permission state'
  fi
  [ ! -e "$(_transaction_lock_dir)" ] || fail_test 'inherited permission state left an ordinary transaction lock'
  [ "$(mode_of "$CONFIG_DIR/original.key")" = 400 ] || fail_test 'ambient permission state widened an existing key'
}

# Run the transaction probe in a fresh Bash process: wrapping a sourced helper
# in the parent's `if` can suppress ERR traps and hide Bash 3's nested-probe bug.
if [ "${1:-}" = --bsd-stat-child ]; then
  (test_bsd_stat_inside_transaction "$2")
  stat_child_status=$?
  exit "$stat_child_status"
fi
if [ "${1:-}" = --ambient-permission-state-child ]; then
  (test_inherited_permission_transaction_state "$2")
  ambient_child_status=$?
  exit "$ambient_child_status"
fi
for stat_helper in mode metadata; do
  if ! "$BASH" "${BASH_SOURCE[0]}" --bsd-stat-child "$stat_helper" >"$TEST_DIR/output" 2>&1; then
    fail_test "$stat_helper stat fallback interfered with ordinary transaction state"
  fi
done

# These are ambient values at process startup, before loading the real modules.
# They must neither select the metadata-only transaction path nor redirect it
# toward unrelated files. A legitimate nested repair must still work.
ambient_canary="$TEST_DIR/ambient-canary.key"
printf '%s\n' DUMMY_UNRELATED_KEY >"$ambient_canary"
command chmod 400 "$ambient_canary"
for ambient_operation in success rollback return-rollback nested-repair; do
  if ! env PERMISSIONS_TRANSACTION_ACTIVE=true \
    PERMISSIONS_TRANSACTION_ROOT="$TEST_DIR" \
    PERMISSIONS_TRANSACTION_ROOT_DEVICE=0 PERMISSIONS_TRANSACTION_ROOT_INODE=0 \
    PERMISSIONS_TXN_PATHS="$ambient_canary" PERMISSIONS_TXN_OLD_MODES=644 \
    PERMISSIONS_TXN_MODES=600 PERMISSIONS_TXN_APPLIED=0 \
    "$BASH" "${BASH_SOURCE[0]}" --ambient-permission-state-child "$ambient_operation" \
    >"$TEST_DIR/output" 2>&1; then
    fail_test "inherited permission state interfered with ordinary $ambient_operation"
  fi
  [ "$(cat "$ambient_canary")" = DUMMY_UNRELATED_KEY ] || fail_test 'inherited metadata paths changed unrelated file contents'
  [ "$(mode_of "$ambient_canary")" = 400 ] || fail_test 'inherited metadata paths changed unrelated file permissions'
done

# A successful child metadata transaction must not complete or replace an
# ordinary outer transaction, its snapshot pointer, or its installed traps.
reset_fixture nested
if ! (
  begin_transaction nested_permission_test "$CONFIG_DIR" || exit 1
  before_depth="${TRANSACTION_DEPTH:-0}"
  before_backup="${PRE_CHANGE_BACKUP:-}"
  before_traps="$(trap -p ERR EXIT)"
  fix_permissions "$CONFIG_DIR" || exit 1
  [ "${TRANSACTION_DEPTH:-0}" = "$before_depth" ] || exit 1
  [ "${PRE_CHANGE_BACKUP:-}" = "$before_backup" ] || exit 1
  [ "$(trap -p ERR EXIT)" = "$before_traps" ] || exit 1
  transaction_is_active || exit 1
  end_transaction_success
) >"$TEST_DIR/output" 2>&1; then
  fail_test 'permission repair interfered with its outer content transaction'
fi
[ "$(mode_of "$CONFIG_DIR/original.key")" = 400 ] || fail_test 'nested repair widened the original key'
[ ! -e "$(_transaction_lock_dir)" ] || fail_test 'nested repair left an outer transaction lock'

reset_fixture restored
if ! (restore_backup "$BACKUP_SOURCE") >"$TEST_DIR/output" 2>&1; then
  fail_test 'real restore failed when it reached real permission repair'
fi
[ "$(cat "$CONFIG_DIR/marker.txt")" = restored ] || fail_test 'successful restore lost new contents'
[ "$(mode_of "$CONFIG_DIR/restored.key")" = 600 ] || fail_test 'restored key was not protected'
[ ! -e "$CONFIG_DIR/original.key" ] || fail_test 'successful restore retained obsolete key'
[ ! -e "$(_transaction_lock_dir)" ] || fail_test 'successful restore left a transaction lock'

# The metadata child reports failure; the ordinary outer restore transaction
# must then recover original file contents exactly once, not only their modes.
reset_fixture failed
FAIL_CHMOD_TARGET="$CONFIG_DIR/restored.key"
if (restore_backup "$BACKUP_SOURCE") >"$TEST_DIR/output" 2>&1; then
  fail_test 'restore reported success after permission repair failed'
fi
[ "$(cat "$CONFIG_DIR/marker.txt")" = original ] || fail_test 'failed restore did not recover original contents'
[ "$(cat "$CONFIG_DIR/original.key")" = DUMMY_ORIGINAL_KEY ] || fail_test 'failed restore lost the original key'
[ "$(mode_of "$CONFIG_DIR/original.key")" = 400 ] || fail_test 'outer rollback changed original key permissions'
[ ! -e "$CONFIG_DIR/restored.key" ] || fail_test 'outer rollback left the failed restored key'
[ ! -e "$(_transaction_lock_dir)" ] || fail_test 'failed restore left a transaction lock'
rollbacks="$(grep -c 'restore_backup failed. Rolled back.' "$TEST_DIR/output" || true)"
[ "$rollbacks" = 1 ] || fail_test 'failed repair did not trigger exactly one successful outer rollback'

printf '[tests] private_key_permissions_restore.sh: PASS\n'
