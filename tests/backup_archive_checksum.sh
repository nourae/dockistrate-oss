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
