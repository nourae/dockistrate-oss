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

# Conditional callers suppress errexit throughout the commit helper. Every
# metadata write must still fail explicitly, restore config, and clear ownership.
for metadata_name in last_post_backup.txt last_rollback_targets.sha256 last_rollback_state.sha256; do
  HTTP_VERSION="http1.1"
  save_config || fail_test "failed to seed metadata write-failure fixture"
  cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.metadata-write.before"
  metadata_path="$BACKUP_DIR/$metadata_name"
  rm "$metadata_path"
  mkdir "$metadata_path"
  HTTP_VERSION="http2"
  if save_config >"$TMP_ROOT/metadata-write.out" 2>&1; then
    fail_test "save_config reported success after $metadata_name write failure"
  fi
  grep -Fq 'Failed to write transaction metadata' "$TMP_ROOT/metadata-write.out" ||
    fail_test "$metadata_name failure did not reach the metadata write check"
  cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.metadata-write.before" ||
    fail_test "$metadata_name failure did not roll back config"
  [ "$HTTP_VERSION" = http1.1 ] || fail_test "$metadata_name failure did not reload original globals"
  if transaction_is_active || [ -e "$(_transaction_lock_dir)" ]; then
    fail_test "$metadata_name failure left a transaction or lock active"
  fi
  [ -z "$(find "$BACKUP_DIR" -name '.last_post_backup.txt.tmp.*' -print)" ] ||
    fail_test "$metadata_name failure left a staged metadata pointer"
  rmdir "$metadata_path"

  # A subsequent transaction must snapshot the recovered state, never reuse
  # the failed operation's post-change archive through mismatched signatures.
  HTTP_VERSION="http1.1"
  begin_transaction_return "after_metadata_failure" "$CONFIG_DIR" ||
    fail_test "cannot start a transaction after $metadata_name failure"
  HTTP_VERSION="http3"
  _save_config_atomic_write || fail_test "cannot mutate follow-up fixture"
  transaction_return_failure >/dev/null 2>&1 || true
  cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.metadata-write.before" ||
    fail_test "$metadata_name failure poisoned rollback snapshot reuse"
done

# Staging and final publication can also fail while file writes themselves work.
eval "$(declare -f make_temp_for_file | sed '1s/make_temp_for_file/original_make_temp_for_file/')"
eval "$(declare -f finalize_temp_file | sed '1s/finalize_temp_file/original_finalize_temp_file/')"
for metadata_failure_stage in stage publish; do
  HTTP_VERSION="http1.1"
  save_config || fail_test "failed to seed metadata publication fixture"
  cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.metadata-publish.before"
  function make_temp_for_file() {
    if [ "$metadata_failure_stage" = stage ] && [ "${2:-}" = "$LAST_POST_BACKUP_FILE" ]; then
      return 1
    fi
    original_make_temp_for_file "$@"
  }
  function finalize_temp_file() {
    if [ "$metadata_failure_stage" = publish ] && [ "${1:-}" = "$LAST_POST_BACKUP_FILE" ]; then
      return 1
    fi
    original_finalize_temp_file "$@"
  }
  HTTP_VERSION="http2"
  if save_config >"$TMP_ROOT/metadata-publish.out" 2>&1; then
    fail_test "save_config reported success after metadata $metadata_failure_stage failure"
  fi
  eval "$(declare -f original_make_temp_for_file | sed '1s/original_make_temp_for_file/make_temp_for_file/')"
  eval "$(declare -f original_finalize_temp_file | sed '1s/original_finalize_temp_file/finalize_temp_file/')"
  grep -Eq 'Failed to (stage|write) transaction metadata' "$TMP_ROOT/metadata-publish.out" ||
    fail_test "metadata $metadata_failure_stage failure lacked a commit diagnostic"
  cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.metadata-publish.before" ||
    fail_test "metadata $metadata_failure_stage failure did not roll back config"
  if transaction_is_active || [ -e "$(_transaction_lock_dir)" ]; then
    fail_test "metadata $metadata_failure_stage failure left a transaction or lock active"
  fi
  [ -z "$(find "$BACKUP_DIR" -name '.last_post_backup.txt.tmp.*' -print)" ] ||
    fail_test "metadata $metadata_failure_stage failure left a staged pointer"
done
unset -f original_make_temp_for_file original_finalize_temp_file

# Preserve the previous signature bytes while reporting a write failure. This
# reproduces an unwritable signature without relying on non-root permissions.
# The next transaction uses the same targets as save_config, so mismatched
# pointer/signature metadata would otherwise reuse the failed post-change state.
HTTP_VERSION="http1.1"
save_config || fail_test "failed to seed signature preservation fixture"
# Archive timestamps may have whole-second precision. Seed exactly representable
# times so replay leaves the previous state signature reusable in this case.
begin_transaction_return "seed_preserved_signature" "$CONFIG_DIR" ||
  fail_test "cannot prepare signature-preservation baseline"
find "$CONFIG_DIR" -exec touch -t 202601020304.05 {} +
end_transaction_success || fail_test "cannot commit signature-preservation baseline"
cp "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/cache-reuse.before"
metadata_previous_targets="$(cat "$BACKUP_DIR/last_rollback_targets.sha256")"
metadata_previous_state="$(cat "$BACKUP_DIR/last_rollback_state.sha256")"
metadata_write_failure_hit=false
function printf() {
  if [ "${FUNCNAME[1]:-}" = end_transaction_success ] && [ "$#" -eq 2 ] &&
    [ "$2" != "$metadata_previous_targets" ] && [[ "$2" =~ ^[0-9a-f]{64}$ ]]; then
    metadata_write_failure_hit=true
    builtin printf '%s\n' "$metadata_previous_state"
    return 1
  fi
  builtin printf "$@"
}
HTTP_VERSION="http2"
if save_config >"$TMP_ROOT/cache-reuse.out" 2>&1; then
  fail_test "save_config ignored the preserved-signature write failure"
fi
unset -f printf
[ "$metadata_write_failure_hit" = true ] || fail_test "state-signature failure was not injected"
[ "$(cat "$BACKUP_DIR/last_rollback_state.sha256")" = "$metadata_previous_state" ] ||
  fail_test "write-failure fixture did not preserve the previous signature"
cmp -s "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/cache-reuse.before" ||
  fail_test "signature failure did not restore original config"
begin_transaction_return "after_preserved_signature_failure" "$CONFIG_DIR" ||
  fail_test "cannot start transaction after preserved-signature failure"
HTTP_VERSION="http3"
_save_config_atomic_write || fail_test "cannot mutate signature-reuse fixture"
transaction_return_failure >/dev/null 2>&1 || true
cmp -s "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/cache-reuse.before" ||
  fail_test "stale metadata reused the failed operation's post-change archive"

cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.before"
eval "$(declare -f csv_join_row | sed '1s/csv_join_row/original_csv_join_row/')"
# Fail the value record after the named header has already been serialized.
_csv_join_row_fail_after=2
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

_csv_join_row_fail_after=2
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
