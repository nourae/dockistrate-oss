# shellcheck shell=bash

function create_backup() {
  _backup_ensure_runtime_defaults
  # If auto-backups are disabled and this is not a forced manual backup, skip
  if [ "$ENABLE_AUTO_BACKUPS" != "true" ] && [ "${1:-}" != "ForceManual" ]; then
    return
  fi

  # Feature helpers run before their outer domain transaction publishes its
  # source/applied model. A journal request also survives subshell callers.
  if [ "${1:-}" != ForceManual ] && [ "${DOMAIN_CONFIG_ACTIVE:-false}" = true ] &&
    [ "${DOMAIN_CONFIG_AUTO_BACKUP_FLUSH:-false}" != true ] &&
    [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] && transaction_is_active; then
    _domain_runtime_put "$DOMAIN_CONFIG_RUNTIME_JOURNAL/transaction.csv" auto_backup_requested yes
    return $?
  fi

  local reason="${2:-}"
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
  if [ "${DOMAIN_CONFIG_AUTO_BACKUP_FLUSH:-false}" = true ]; then
    backup_name="${backup_name}_${DOMAIN_CONFIG_RUNTIME_JOURNAL##*.}"
  fi
  if ! is_valid_backup_name "$backup_name"; then
    echo "[Error] Generated backup name is invalid: $backup_name" >&2
    return 1
  fi
  local backup_path=""

  local cur_checksum="" domain_backup=false
  if declare -F domain_config_active >/dev/null 2>&1 && domain_config_active; then
    domain_backup=true
    cur_checksum="$(domain_config_backup_checksum)" || return 1
  elif [ -d "$CONFIG_DIR" ]; then
    cur_checksum="$(_config_checksum "$CONFIG_DIR")"
  fi
  local last_checksum=""
  [ -f "$FULL_BACKUP_CHECKSUM_FILE" ] && last_checksum="$(cat "$FULL_BACKUP_CHECKSUM_FILE")"
  if [ "$cur_checksum" = "$last_checksum" ] && [ "${1:-}" != "ForceManual" ]; then
    return
  fi

  local old_umask
  old_umask="$(umask)"
  umask 077
  if ! _ensure_backup_dir_secure; then
    umask "$old_umask"
    return 1
  fi
  if ! _backup_resolve_path_within_root backup_path "${BACKUP_DIR}/${backup_name}"; then
    umask "$old_umask"
    return 1
  fi

  if [ "${DOMAIN_CONFIG_AUTO_BACKUP_FLUSH:-false}" = true ]; then
    if [ -e "$backup_path" ] || [ -L "$backup_path" ] ||
      [ -e "${backup_path}.tar.gz" ] || [ -L "${backup_path}.tar.gz" ] ||
      [ -e "${backup_path}.tar.gz.sha256" ] || [ -L "${backup_path}.tar.gz.sha256" ]; then
      echo '[Error] Automatic backup output already exists.' >&2
      umask "$old_umask"
      return 1
    fi
    # Record ownership before creation so interrupted, uncommitted operations
    # can discard only this output and restore the previous public markers.
    if ! _domain_runtime_put "$DOMAIN_CONFIG_RUNTIME_JOURNAL/automatic_backup/state.csv" output "$backup_path" ||
      ! mkdir "$backup_path"; then
      umask "$old_umask"
      return 1
    fi
  elif ! mkdir -p "$backup_path"; then
    echo "[Warn] Failed to create backup directory at $backup_path. Skipping backup."
    umask "$old_umask"
    return
  fi
  chmod 700 "$backup_path" 2>/dev/null || true

  if [ "$domain_backup" = true ]; then
    if ! domain_config_backup_write "$backup_path"; then
      echo '[Error] Failed to snapshot domain configuration and certificate material.' >&2
      _backup_safe_rm_rf "$backup_path" || true
      umask "$old_umask"
      return 1
    fi
    # A draft may have changed since deduplication inspected it. The saved
    # checksum must describe this backup's actual payload.
    if ! cur_checksum="$(cd "$backup_path" && _config_checksum .)"; then
      _backup_safe_rm_rf "$backup_path" || true
      umask "$old_umask"
      return 1
    fi
  elif [ -d "$CONFIG_DIR" ]; then
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
  if ! {
    printf '%s\n' "$cur_checksum" >"$FULL_BACKUP_CHECKSUM_FILE" &&
      printf '%s\n' "$backup_path" >"$FULL_BACKUP_FILE"
  }; then
    umask "$old_umask"
    return 1
  fi
  log_msg "Created backup: $backup_name"

  # Provisional automatic outputs must not prune rollback evidence before the
  # durable commit. Their retention runs from committed journal cleanup.
  if [ "${DOMAIN_CONFIG_AUTO_BACKUP_FLUSH:-false}" != true ]; then
    _backup_enforce_retention
  fi
  umask "$old_umask"
}

function _backup_enforce_retention() {
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
}
