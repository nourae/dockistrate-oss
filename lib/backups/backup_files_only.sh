# shellcheck shell=bash

# Create a compressed backup containing only specified files relative to STATE_DIR
function backup_files_only() {
  _backup_ensure_runtime_defaults
  local reason="${1:-Files}"
  shift
  [ $# -eq 0 ] && return 1
  local base_dir="${STATE_DIR:-$BASE_DIR}"
  local timestamp="$(date '+%Y%m%d_%H%M%S')"
  local safe_reason
  safe_reason="$(_sanitize_backup_label "$reason")"
  if [[ -z "$safe_reason" || ! "$safe_reason" =~ [A-Za-z0-9] ]]; then
    safe_reason="Files"
  fi
  local archive_name="${timestamp}_${safe_reason}.tar.gz"
  if ! is_valid_backup_name "$archive_name"; then
    echo "[Error] Invalid backup archive name: $archive_name" >&2
    return 1
  fi
  local archive="${BACKUP_DIR}/${archive_name}"

  local old_umask
  old_umask="$(umask)"
  umask 077
  _ensure_backup_dir_secure
  local rel_paths=()
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    if [[ "$f" == "$base_dir"* ]]; then
      rel_paths+=("${f#$base_dir/}")
    else
      rel_paths+=("$f")
    fi
  done

  if [ ${#rel_paths[@]} -eq 0 ]; then
    # Create an empty archive when no files are present to avoid tar errors.
    # GNU tar supports "--files-from /dev/null", but BSD tar (macOS default)
    # does not. Detect the implementation so the command succeeds everywhere.
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
      LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$archive" --files-from /dev/null
    else
      local empty_dir
      empty_dir="$(mktemp -d "${TMP_DIR:-/tmp}/dockistrate_empty_tar.XXXXXX")"
      # BSD tar cannot read an empty file list, so create an empty directory and
      # archive it. The resulting archive only contains the root entry and
      # extracts cleanly on both GNU and BSD tar implementations.
      (cd "$empty_dir" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$archive" .)
      rmdir "$empty_dir"
    fi
  else
    (cd "$base_dir" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$archive" "${rel_paths[@]}")
  fi
  chmod 600 "$archive" 2>/dev/null || true
  if ! _write_backup_archive_checksum "$archive"; then
    rm -f "$archive"
    umask "$old_umask"
    echo "[Error] Failed to write checksum sidecar for transaction backup archive." >&2
    return 1
  fi
  umask "$old_umask"
  echo "$archive"
}
