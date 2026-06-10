#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils/fs.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups/common.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_backup_guard.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BACKUP_DIR="${TMP_ROOT}/backups"
mkdir -p "$BACKUP_DIR"

inside_file="${BACKUP_DIR}/inside.txt"
inside_dir="${BACKUP_DIR}/inside_dir"
outside_dir="${TMP_ROOT}/outside"
outside_file="${outside_dir}/outside.txt"

mkdir -p "$inside_dir" "$outside_dir"
touch "$inside_file" "${inside_dir}/nested.txt" "$outside_file"

if ! _backup_safe_rm_f "$inside_file"; then
  echo "[Error] _backup_safe_rm_f failed to remove file inside BACKUP_DIR." >&2
  exit 1
fi
if [ -e "$inside_file" ]; then
  echo "[Error] _backup_safe_rm_f did not remove inside file." >&2
  exit 1
fi

if ! _backup_safe_rm_rf "$inside_dir"; then
  echo "[Error] _backup_safe_rm_rf failed to remove directory inside BACKUP_DIR." >&2
  exit 1
fi
if [ -e "$inside_dir" ]; then
  echo "[Error] _backup_safe_rm_rf did not remove inside directory." >&2
  exit 1
fi

set +e
_backup_safe_rm_f "$outside_file" >/dev/null 2>&1
outside_file_status=$?
_backup_safe_rm_rf "$outside_dir" >/dev/null 2>&1
outside_dir_status=$?
set -e

if [ "$outside_file_status" -eq 0 ] || [ "$outside_dir_status" -eq 0 ]; then
  echo "[Error] Backup safe-delete helpers accepted paths outside BACKUP_DIR." >&2
  exit 1
fi
if [ ! -f "$outside_file" ] || [ ! -d "$outside_dir" ]; then
  echo "[Error] Outside paths were modified by backup safe-delete helpers." >&2
  exit 1
fi

if ! _backup_resolve_path_within_root resolved_inside "${BACKUP_DIR}/future.tar.gz"; then
  echo "[Error] _backup_resolve_path_within_root rejected valid backup-root path." >&2
  exit 1
fi

set +e
_backup_resolve_path_within_root resolved_outside "$outside_file" >/dev/null 2>&1
outside_resolve_status=$?
set -e
if [ "$outside_resolve_status" -eq 0 ]; then
  echo "[Error] _backup_resolve_path_within_root accepted a path outside BACKUP_DIR." >&2
  exit 1
fi

echo "Backup path guard checks passed."
