# shellcheck shell=bash

function _normalize_transaction_backup_target() {
  local target="${1:-}" normalized=""
  [ -n "$target" ] || return 1

  normalized="$target"
  while [ "${normalized%/}" != "$normalized" ] && [ "$normalized" != "/" ]; do
    normalized="${normalized%/}"
  done
  if [ "${normalized#/}" = "$normalized" ]; then
    normalized="$PWD/${normalized#./}"
  fi

  # Resolve parent aliases before overlap checks, but never turn an unsafe
  # symlink leaf into an apparently ordinary snapshot target.
  [ ! -L "$normalized" ] || return 1
  if [ ! -e "$normalized" ] && declare -F _runtime_path_resolve_allow_missing >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$normalized" "new transaction target" || return 1
    _runtime_path_resolve_allow_missing "$normalized"
    return $?
  fi
  if [ -d "$normalized" ]; then
    normalized="$(cd "$normalized" && pwd -P && printf '.')" || return 1
    normalized="${normalized%$'\n.'}"
    printf '%s' "$normalized"
  else
    _realpath_portable "$normalized"
  fi
}

# Create a compressed backup containing only specified files relative to STATE_DIR
function backup_files_only() {
  _backup_ensure_runtime_defaults
  local reason="${1:-Files}"
  shift
  [ $# -eq 0 ] && return 1
  local base_dir="${STATE_DIR:-$BASE_DIR}"
  local timestamp=""
  timestamp="$(date '+%Y%m%d_%H%M%S')" || return 1
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
  local archive="" archive_reservation=""

  local old_umask archive_locale=""
  archive_locale="$(_transaction_archive_locale)" || return 1
  old_umask="$(umask)"
  umask 077
  if ! _ensure_backup_dir_secure; then
    umask "$old_umask"
    return 1
  fi

  local base_dir_physical=""
  if ! base_dir_physical="$(_realpath_portable "$base_dir" 2>/dev/null && printf '.')"; then
    umask "$old_umask"
    echo "[Error] Unable to resolve transaction backup root: $base_dir" >&2
    return 1
  fi
  base_dir_physical="${base_dir_physical%.}"

  local rel_paths=() snapshot_targets=()
  local f="" file_physical="" existing_target="" skip_target=false
  for f in "$@"; do
    while [ "${f%/}" != "$f" ] && [ "$f" != / ]; do f="${f%/}"; done
    if [ -L "$f" ]; then
      umask "$old_umask"
      echo "[Error] Refusing symlinked transaction backup path: $f" >&2
      return 1
    fi

    if ! file_physical="$(_normalize_transaction_backup_target "$f" 2>/dev/null && printf '.')"; then
      umask "$old_umask"
      echo "[Error] Refusing unresolved transaction backup path: $f" >&2
      return 1
    fi
    file_physical="${file_physical%.}"

    case "$file_physical" in
    "$base_dir_physical")
      umask "$old_umask"
      echo "[Error] Refusing transaction backup path at the state root itself: $f" >&2
      return 1
      ;;
    "$base_dir_physical"/*) ;;
    *)
      umask "$old_umask"
      echo "[Error] Refusing transaction backup path outside state root: $f" >&2
      return 1
      ;;
    esac
    [[ -e "$file_physical" ]] || continue
    skip_target=false
    for existing_target in "${snapshot_targets[@]-}"; do
      [ -n "$existing_target" ] || continue
      case "$file_physical" in
      "$existing_target" | "$existing_target"/*) skip_target=true; break ;;
      esac
    done
    [ "$skip_target" = false ] || continue
    local kept_targets=()
    for existing_target in "${snapshot_targets[@]-}"; do
      [ -n "$existing_target" ] || continue
      case "$existing_target" in
      "$file_physical"/*) ;;
      *) kept_targets+=("$existing_target") ;;
      esac
    done
    snapshot_targets=()
    for existing_target in "${kept_targets[@]-}"; do
      [ -n "$existing_target" ] && snapshot_targets+=("$existing_target")
    done
    snapshot_targets+=("$file_physical")
  done

  if [ "${#snapshot_targets[@]}" -gt 0 ]; then
    if ! _validate_transaction_backup_targets "$base_dir_physical" "${snapshot_targets[@]}"; then
      umask "$old_umask"
      return 1
    fi
    for file_physical in "${snapshot_targets[@]}"; do
      rel_paths+=("${file_physical#"$base_dir_physical"/}")
    done
  fi

  # Keep the timestamp, transaction marker and extension used by backup
  # helpers, while giving each retained recovery snapshot its own pathname.
  # noclobber reserves the final name atomically even if a random token repeats.
  if ! archive_reservation="$(mktemp "${BACKUP_DIR}/${timestamp}_${safe_reason}_XXXXXX")"; then
    umask "$old_umask"
    echo "[Error] Failed to reserve transaction backup archive." >&2
    return 1
  fi
  archive="${archive_reservation}.tar.gz"
  if ! (set -C; : >"$archive") 2>/dev/null; then
    rm -f "$archive_reservation"
    umask "$old_umask"
    echo "[Error] Refusing to replace an existing transaction backup archive: $archive" >&2
    return 1
  fi
  rm -f "$archive_reservation"

  if [ ${#rel_paths[@]} -eq 0 ]; then
    # Create an empty archive when no files are present to avoid tar errors.
    # GNU tar supports "--files-from /dev/null", but BSD tar (macOS default)
    # does not. Detect the implementation so the command succeeds everywhere.
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
      if ! TAR_OPTIONS='' LC_ALL="$archive_locale" COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$archive" --files-from /dev/null; then
        rm -f "$archive" "$archive.sha256"
        umask "$old_umask"
        echo "[Error] Failed to create transaction backup archive." >&2
        return 1
      fi
    else
      local empty_dir
      empty_dir="$(mktemp -d "${TMP_DIR:-/tmp}/dockistrate_empty_tar.XXXXXX")"
      # BSD tar cannot read an empty file list, so create an empty directory and
      # archive it. The resulting archive only contains the root entry and
      # extracts cleanly on both GNU and BSD tar implementations.
      if ! (cd "$empty_dir" && TAR_OPTIONS='' LC_ALL="$archive_locale" COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$archive" .); then
        rmdir "$empty_dir" 2>/dev/null || true
        rm -f "$archive" "$archive.sha256"
        umask "$old_umask"
        echo "[Error] Failed to create transaction backup archive." >&2
        return 1
      fi
      rmdir "$empty_dir"
    fi
  else
    if ! (cd "$base_dir_physical" && TAR_OPTIONS='' LC_ALL="$archive_locale" COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$archive" -- "${rel_paths[@]}"); then
      rm -f "$archive" "$archive.sha256"
      umask "$old_umask"
      echo "[Error] Failed to create transaction backup archive." >&2
      return 1
    fi
  fi
  chmod 600 "$archive" 2>/dev/null || true
  if ! _write_backup_archive_checksum "$archive"; then
    rm -f "$archive" "$archive.sha256"
    umask "$old_umask"
    echo "[Error] Failed to write checksum sidecar for transaction backup archive." >&2
    return 1
  fi
  umask "$old_umask"
  echo "$archive"
}
