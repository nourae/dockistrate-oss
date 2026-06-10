# shellcheck shell=bash

function create_backup() {
  _backup_ensure_runtime_defaults
  # If auto-backups are disabled and this is not a forced manual backup, skip
  if [ "$ENABLE_AUTO_BACKUPS" != "true" ] && [ "$1" != "ForceManual" ]; then
    return
  fi

  local reason="$2"
  [ -z "$reason" ] && reason="Auto"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$CONFIG_DIR" "backup config source" || return 1
    runtime_state_path_guard_if_declared "$BACKUP_DIR" "backup directory" || return 1
  fi
  local timestamp
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  local reason_sanitized
  reason_sanitized="$(_sanitize_backup_label "$reason")"
  if [[ -z "$reason_sanitized" || ! "$reason_sanitized" =~ [A-Za-z0-9] ]]; then
    reason_sanitized="Auto"
  fi
  local backup_name="${timestamp}_${reason_sanitized}"
  if ! is_valid_backup_name "$backup_name"; then
    echo "[Error] Generated backup name is invalid: $backup_name" >&2
    return 1
  fi
  local backup_path=""

  local cur_checksum=""
  if [ -d "$CONFIG_DIR" ]; then
    cur_checksum="$(_config_checksum "$CONFIG_DIR")"
  fi
  local last_checksum=""
  [ -f "$FULL_BACKUP_CHECKSUM_FILE" ] && last_checksum="$(cat "$FULL_BACKUP_CHECKSUM_FILE")"
  if [ "$cur_checksum" = "$last_checksum" ] && [ "$1" != "ForceManual" ]; then
    return
  fi

  local old_umask
  old_umask="$(umask)"
  umask 077
  _ensure_backup_dir_secure
  if ! _backup_resolve_path_within_root backup_path "${BACKUP_DIR}/${backup_name}"; then
    umask "$old_umask"
    return 1
  fi

  if ! mkdir -p "$backup_path"; then
    echo "[Warn] Failed to create backup directory at $backup_path. Skipping backup."
    umask "$old_umask"
    return
  fi
  chmod 700 "$backup_path" 2>/dev/null || true

  if [ -d "$CONFIG_DIR" ]; then
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$CONFIG_DIR" "backup config source" || {
        _backup_safe_rm_rf "$backup_path" || true
        umask "$old_umask"
        return 1
      }
    fi
    if ! cp -r "$CONFIG_DIR" "$backup_path/"; then
      echo "[Error] Failed to copy config into backup. Aborting backup." >&2
      _backup_safe_rm_rf "$backup_path" || true
      umask "$old_umask"
      return 1
    fi
  fi

  if [ "$ENABLE_BACKUP_COMPRESSION" = "true" ]; then
    local archive_path=""
    if ! _backup_resolve_path_within_root archive_path "${backup_path}.tar.gz"; then
      _backup_safe_rm_rf "$backup_path" || true
      umask "$old_umask"
      return 1
    fi
    if LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$archive_path" -C "$BACKUP_DIR" "$backup_name"; then
      chmod 600 "$archive_path" 2>/dev/null || true
      if _write_backup_archive_checksum "$archive_path"; then
        _backup_safe_rm_rf "$backup_path" || true
        backup_path="$archive_path"
        echo "[Info] Backup compressed to: $backup_path"
      else
        _backup_safe_rm_f "$archive_path" || true
        _backup_safe_rm_f "${archive_path}.sha256" || true
        chmod 700 "$backup_path" 2>/dev/null || true
        echo "[Warn] Failed to write checksum for compressed backup at $archive_path. Leaving directory uncompressed." >&2
      fi
    else
      _backup_safe_rm_f "$archive_path" || true
      chmod 700 "$backup_path" 2>/dev/null || true
      echo "[Warn] Failed to compress backup at $backup_path. Leaving directory uncompressed." >&2
    fi
  else
    chmod 700 "$backup_path" 2>/dev/null || true
    echo "[Info] Backup folder created at: $backup_path"
  fi
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$FULL_BACKUP_CHECKSUM_FILE" "$FULL_BACKUP_FILE" || {
      umask "$old_umask"
      return 1
    }
  fi
  echo "$cur_checksum" >"$FULL_BACKUP_CHECKSUM_FILE"
  echo "$backup_path" >"$FULL_BACKUP_FILE"
  log_msg "Created backup: $backup_name"

  # Enforce retention if set
  if [ "$BACKUP_RETENTION" -gt 0 ]; then
    echo "[Info] Enforcing backup retention of $BACKUP_RETENTION day(s)..."
    local stale_file
    while IFS= read -r -d '' stale_file; do
      _backup_safe_rm_f "${stale_file}.sha256" || true
      _backup_safe_rm_f "$stale_file" || true
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.tar.gz" -mtime +"$BACKUP_RETENTION" -print0 2>/dev/null)

    local stale_dir
    while IFS= read -r -d '' stale_dir; do
      _backup_safe_rm_rf "$stale_dir" || true
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "[0-9]*_*" -mtime +"$BACKUP_RETENTION" -print0 2>/dev/null)
  fi
  umask "$old_umask"
}
