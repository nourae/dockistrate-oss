# shellcheck shell=bash

# Restore a backup archive created by backup_files_only
function restore_backup_archive() {
  local archive="${1:-}"
  if [ ! -f "$archive" ]; then
    return 0
  fi
  local base_dir="${STATE_DIR:-$BASE_DIR}"
  _verify_backup_archive_checksum_if_present "$archive" || return 1
  _safe_extract_tar "$archive" "$base_dir"
}
