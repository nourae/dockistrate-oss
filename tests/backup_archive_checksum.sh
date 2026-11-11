#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_backup_checksum.XXXXXX")")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha256"
FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
ENABLE_BACKUP_COMPRESSION=true
ENABLE_AUTO_BACKUPS=true
BACKUP_RETENTION=1
NGINX_CONTAINER_NAME="dockistrate-nginx"

function log_msg() { :; }

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR"
printf 'value\n' >"$CONFIG_DIR/example.conf"

archive="$(backup_files_only checksum_case "$CONFIG_DIR/example.conf")"
if [ ! -f "$archive.sha256" ]; then
  echo "[Error] backup_files_only did not write checksum sidecar." >&2
  exit 1
fi

rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
restore_backup_archive "$archive"
if [ "$(cat "$CONFIG_DIR/example.conf")" != "value" ]; then
  echo "[Error] restore_backup_archive did not restore checksum-protected archive." >&2
  exit 1
fi

# Replacing the operator-supplied pathname after validation must not change the
# archive being extracted. The private snapshot should remain the sole source.
race_safe_root="$TMP_ROOT/race-safe"
race_bad_root="$TMP_ROOT/race-bad"
race_archive="$BACKUP_DIR/race.tar.gz"
race_bad_archive="$TMP_ROOT/race-bad.tar.gz"
race_swap_marker="$TMP_ROOT/race-swapped"
mkdir -p "$race_safe_root/race_payload" "$race_bad_root/race_payload/config"
printf 'safe\n' >"$race_safe_root/race_payload/safe.txt"
ln -s "$TMP_ROOT/race-link-target" "$race_bad_root/race_payload/config/link"
(cd "$race_safe_root" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$race_archive" race_payload)
(cd "$race_bad_root" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$race_bad_archive" race_payload)
_write_backup_archive_checksum "$race_archive"

race_real_tar="$(command -v tar)"
function tar() {
  case "${1:-}" in
  -xzf | -xozf)
    if [ ! -e "$race_swap_marker" ]; then
      mv "$race_bad_archive" "$race_archive"
      : >"$race_swap_marker"
    fi
    ;;
  esac
  "$race_real_tar" "$@"
}

rm -rf "$STATE_DIR/race_payload"
restore_backup_archive "$race_archive"
unset -f tar
if [ ! -e "$race_swap_marker" ]; then
  echo "[Error] Archive pathname swap fixture did not run." >&2
  exit 1
fi
if [ "$(cat "$STATE_DIR/race_payload/safe.txt" 2>/dev/null || true)" != "safe" ]; then
  echo "[Error] Restore did not extract the validated private archive snapshot." >&2
  exit 1
fi
if [ -e "$STATE_DIR/race_payload/config/link" ] || [ -L "$STATE_DIR/race_payload/config/link" ]; then
  echo "[Error] Restore extracted a post-validation archive pathname replacement." >&2
  exit 1
fi

# Backup writers must fail closed and restore the caller's umask when the
# runtime backup-directory guard rejects the destination.
function _ensure_backup_dir_secure() { return 1; }

function backup_entry_count() {
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]'
}

guard_count_before="$(backup_entry_count)"
guard_umask_before="$(umask)"
set +e
backup_files_only GuardFiles "$CONFIG_DIR/example.conf" >"$TMP_ROOT/guard-files.out" 2>/dev/null
guard_files_status=$?
set -e
if [ "$guard_files_status" -eq 0 ]; then
  echo "[Error] backup_files_only ignored backup-directory guard failure." >&2
  exit 1
fi
if [ "$(umask)" != "$guard_umask_before" ]; then
  echo "[Error] backup_files_only did not restore umask after backup-directory guard failure." >&2
  exit 1
fi
if [ "$(backup_entry_count)" != "$guard_count_before" ]; then
  echo "[Error] backup_files_only wrote backup artifacts after backup-directory guard failure." >&2
  exit 1
fi

set +e
create_backup ForceManual GuardCreate >"$TMP_ROOT/guard-create.out" 2>/dev/null
guard_create_status=$?
set -e
if [ "$guard_create_status" -eq 0 ]; then
  echo "[Error] create_backup ignored backup-directory guard failure." >&2
  exit 1
fi
if [ "$(umask)" != "$guard_umask_before" ]; then
  echo "[Error] create_backup did not restore umask after backup-directory guard failure." >&2
  exit 1
fi
if [ "$(backup_entry_count)" != "$guard_count_before" ]; then
  echo "[Error] create_backup wrote backup artifacts after backup-directory guard failure." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups/common.sh"

# Transaction backups must reject sibling-prefix, outside-root, and symlink
# targets without changing the caller's umask or leaving archive artifacts.
function assert_transaction_backup_path_rejected() {
  local label="${1:-}" target="${2:-}" expected="${3:-}"
  local count_before="" umask_before="" status=0
  count_before="$(backup_entry_count)"
  umask_before="$(umask)"

  set +e
  backup_files_only "$label" "$target" >"$TMP_ROOT/${label}.out" 2>"$TMP_ROOT/${label}.err"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "[Error] backup_files_only accepted unsafe target: $target" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$TMP_ROOT/${label}.err"; then
    echo "[Error] backup_files_only did not report the expected containment failure for $target." >&2
    cat "$TMP_ROOT/${label}.err" >&2
    exit 1
  fi
  if [ "$(umask)" != "$umask_before" ]; then
    echo "[Error] backup_files_only did not restore umask after rejecting $target." >&2
    exit 1
  fi
  if [ "$(backup_entry_count)" != "$count_before" ]; then
    echo "[Error] backup_files_only wrote artifacts after rejecting $target." >&2
    exit 1
  fi
}

outside_prefix_dir="${STATE_DIR}-outside"
outside_absolute_dir="$TMP_ROOT/absolute-outside"
mkdir -p "$outside_prefix_dir" "$outside_absolute_dir"
printf 'outside\n' >"$outside_prefix_dir/prefix.conf"
printf 'outside\n' >"$outside_absolute_dir/absolute.conf"
assert_transaction_backup_path_rejected OutsidePrefix "$outside_prefix_dir/prefix.conf" "outside state root"
assert_transaction_backup_path_rejected OutsideAbsolute "$outside_absolute_dir/absolute.conf" "outside state root"
assert_transaction_backup_path_rejected OutsideMissing "$outside_absolute_dir/missing.conf" "outside state root"
assert_transaction_backup_path_rejected OutsideMissingNested "$outside_absolute_dir/missing-parent/child.conf" "outside state root"

# Initial domain application snapshots targets whose parent directories do not
# exist yet. They remain contained, and snapshotting must not create them.
missing_nested_archive="$(backup_files_only MissingNested "$STATE_DIR/missing-parent/child.conf")"
if [ ! -f "$missing_nested_archive.sha256" ] || [ -e "$STATE_DIR/missing-parent" ]; then
  echo "[Error] New nested rollback target was rejected or created during snapshotting." >&2
  exit 1
fi

missing_inside_archive="$(backup_files_only MissingInside "$CONFIG_DIR/new.conf")"
if [ ! -f "$missing_inside_archive" ] || [ ! -f "$missing_inside_archive.sha256" ]; then
  echo "[Error] backup_files_only rejected a new rollback target beneath an existing in-state parent." >&2
  exit 1
fi

live_target="$CONFIG_DIR/live-target.conf"
live_link="$STATE_DIR/live-rollback-target"
printf 'inside\n' >"$live_target"
ln -s "$live_target" "$live_link"
assert_transaction_backup_path_rejected LiveSymlink "$live_link" "symlinked transaction backup path"

broken_target="$STATE_DIR/broken-rollback-target"
ln -s "$STATE_DIR/missing-rollback-target" "$broken_target"
assert_transaction_backup_path_rejected BrokenSymlink "$broken_target" "symlinked transaction backup path"

corrupt_archive="$BACKUP_DIR/corrupt.tar.gz"
cp "$archive" "$corrupt_archive"
cp "$archive.sha256" "$corrupt_archive.sha256"
printf 'corruption\n' >>"$corrupt_archive"
set +e
restore_backup_archive "$corrupt_archive" >/dev/null 2>&1
corrupt_status=$?
set -e
if [ "$corrupt_status" -eq 0 ]; then
  echo "[Error] Corrupted archive with checksum sidecar restored successfully." >&2
  exit 1
fi

legacy_root="$TMP_ROOT/legacy_payload"
legacy_dir="$legacy_root/legacy"
mkdir -p "$legacy_dir/config"
printf 'legacy\n' >"$legacy_dir/config/legacy.conf"
legacy_archive="$BACKUP_DIR/legacy.tar.gz"
(cd "$legacy_root" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$legacy_archive" legacy)
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
restore_backup_archive "$legacy_archive" >/dev/null 2>"$TMP_ROOT/legacy.err"
if [ ! -f "$STATE_DIR/legacy/config/legacy.conf" ]; then
  echo "[Error] Legacy archive without sidecar should still restore." >&2
  exit 1
fi
if ! grep -Fq 'No checksum sidecar found' "$TMP_ROOT/legacy.err"; then
  echo "[Error] Legacy archive restore should warn when checksum sidecar is absent." >&2
  exit 1
fi

stale_archive="$BACKUP_DIR/20000101_000000_old.tar.gz"
printf 'old\n' >"$stale_archive"
printf 'old\n' >"$stale_archive.sha256"
touch -t 200001010000 "$stale_archive" "$stale_archive.sha256"
create_backup ForceManual Manual >/dev/null
if [ -e "$stale_archive" ] || [ -e "$stale_archive.sha256" ]; then
  echo "[Error] Backup retention did not remove stale archive and sidecar." >&2
  exit 1
fi

created_full_backup="$(cat "$FULL_BACKUP_FILE")"
if [ ! -f "${created_full_backup}.sha256" ]; then
  echo "[Error] Compressed full backup missing checksum sidecar." >&2
  exit 1
fi

if list_backups | grep -Fq '.sha256'; then
  echo "[Error] list_backups should hide checksum sidecars." >&2
  exit 1
fi

echo "[tests] backup_archive_checksum.sh: PASS"
