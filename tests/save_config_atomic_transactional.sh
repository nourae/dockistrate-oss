#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"

ORIG_BACKUP_FILES_ONLY_DEF="$(declare -f backup_files_only)"
ORIG_BACKUP_FILES_ONLY_CALL_DEF="$(declare -f backup_files_only | sed '1s/backup_files_only/original_backup_files_only/')"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_save_config.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

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
save_config || fail_test "initial save_config should succeed"

HTTP_VERSION="http1.1"
save_config || fail_test "standalone save_config should succeed"
[ -f "$LAST_POST_BACKUP_FILE" ] || fail_test "save_config should record a post-change backup"
post_backup="$(cat "$LAST_POST_BACKUP_FILE")"
[ -n "$post_backup" ] || fail_test "save_config should store a post-change backup path"
[ -f "$post_backup" ] || fail_test "save_config post-change backup archive not found"
case "$post_backup" in
*post_save_config*) ;;
*) fail_test "save_config should create a post_save_config archive (got $post_backup)" ;;
esac

cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.commit.before"
commit_failure_post_backup="$post_backup"
rm -f "$BACKUP_DIR/last_rollback_targets.sha256" "$BACKUP_DIR/last_rollback_state.sha256"
eval "$ORIG_BACKUP_FILES_ONLY_CALL_DEF"
backup_files_only_counter_file="$TMP_ROOT/backup_files_only.count"
printf '0\n' >"$backup_files_only_counter_file"
backup_files_only() {
  local calls=0
  calls="$(cat "$backup_files_only_counter_file")"
  calls=$((calls + 1))
  printf '%s\n' "$calls" >"$backup_files_only_counter_file"
  if [ "$calls" -eq 1 ]; then
    original_backup_files_only "$@"
    return
  fi
  return 1
}

set +e
HTTP_VERSION="http2"
save_config >/dev/null 2>&1
status=$?
set -e

unset -f backup_files_only
eval "$ORIG_BACKUP_FILES_ONLY_DEF"
unset -f original_backup_files_only
[ "$status" -ne 0 ] || fail_test "save_config should fail when post-change backup creation fails"
cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.commit.before" || fail_test "save_config should restore the original file after post-change backup failure"
[ "$(cat "$LAST_POST_BACKUP_FILE")" = "$commit_failure_post_backup" ] || fail_test "save_config should preserve the previous post-change backup marker when commit backup creation fails"
if transaction_is_active; then
  fail_test "save_config should clear the transaction after post-change backup failure"
fi

cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.metadata.before"
safe_last_post_backup_file="$LAST_POST_BACKUP_FILE"
metadata_external="$TMP_ROOT/external-metadata"
metadata_link="$BACKUP_DIR/metadata-link"
mkdir -p "$metadata_external"
ln -s "$metadata_external" "$metadata_link"
LAST_POST_BACKUP_FILE="$metadata_link/last_post_backup.txt"

set +e
HTTP_VERSION="http3"
save_config >/dev/null 2>&1
status=$?
set -e

[ "$status" -ne 0 ] || fail_test "save_config should fail when transaction metadata path guard rejects a symlink"
cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.metadata.before" || fail_test "save_config should roll back config after transaction metadata guard failure"
[ ! -e "$metadata_external/last_post_backup.txt" ] || fail_test "transaction metadata guard failure wrote through a symlink"
if transaction_is_active; then
  fail_test "save_config should clear the transaction after transaction metadata guard failure"
fi
if [ -e "$(_transaction_lock_dir)" ] || [ -L "$(_transaction_lock_dir)" ]; then
  fail_test "save_config should release the transaction lock after transaction metadata guard failure"
fi
LAST_POST_BACKUP_FILE="$safe_last_post_backup_file"

cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.before"
eval "$(declare -f csv_join_row | sed '1s/csv_join_row/original_csv_join_row/')"
_csv_join_row_fail_after=4
csv_join_row() {
  _csv_join_row_call_count=$((_csv_join_row_call_count + 1))
  if [ "${_csv_join_row_call_count}" -eq "${_csv_join_row_fail_after}" ]; then
    return 1
  fi
  original_csv_join_row "$@"
}

set +e
(
  _csv_join_row_call_count=0
  HTTP_VERSION="http2"
  save_config
) >/dev/null 2>&1
status=$?
set -e

unset -f csv_join_row
unset -f original_csv_join_row
[ "$status" -ne 0 ] || fail_test "save_config should fail when CSV row generation fails"
cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.before" || fail_test "save_config should leave the original file intact on write failure"
[ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.global_settings.csv.tmp.*' -print -quit)" ] || fail_test "save_config should clean up temporary files after failure"

marker_dir="$TMP_ROOT/subshell-marker"
mkdir -p "$marker_dir"
trap '[ -d "$marker_dir" ] && touch "$marker_dir/inherited-exit"' EXIT

function original_csv_join_row() {
  local out="" field escaped=""
  if [ "$#" -eq 0 ]; then
    printf '\n'
    return 0
  fi

  for field in "$@"; do
    escaped="$(csv_escape_field "$field")"
    if [ -z "$out" ]; then
      out="$escaped"
    else
      out="${out},${escaped}"
    fi
  done

  printf '%s\n' "$out"
}

_csv_join_row_fail_after=4
csv_join_row() {
  _csv_join_row_call_count=$((_csv_join_row_call_count + 1))
  if [ "${_csv_join_row_call_count}" -eq "${_csv_join_row_fail_after}" ]; then
    return 1
  fi
  original_csv_join_row "$@"
}

set +e
(
  set +e
  _csv_join_row_call_count=0
  HTTP_VERSION="http2"
  save_config >/dev/null 2>&1 || true
)
status=$?
set -e

unset -f csv_join_row
unset -f original_csv_join_row
[ "$status" -eq 0 ] || fail_test "failing save_config in a subshell should return control to the subshell caller"
[ ! -e "$marker_dir/inherited-exit" ] || fail_test "save_config failure in a subshell must not reactivate an inherited EXIT trap"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "save_config atomic + transaction checks passed."
