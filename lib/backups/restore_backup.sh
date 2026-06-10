# shellcheck shell=bash

function restore_backup() {
  local backup_ref="${1:-}"
  [ -z "$backup_ref" ] && {
    echo "[Usage] restore-backup <backup_name|backup_path>"
    exit 1
  }
  local backup_item="" backup_label="$backup_ref"
  if [ -e "$backup_ref" ]; then
    backup_item="$backup_ref"
  else
    case "$backup_ref" in
    /* | ./* | ../* | */*)
      backup_item="$backup_ref"
      ;;
    *)
      require_valid_backup_name "$backup_ref" || exit 1
      backup_item="${BACKUP_DIR}/${backup_ref}"
      ;;
    esac
  fi

  if [ ! -e "$backup_item" ]; then
    echo "[Error] Backup not found: $backup_item" >&2
    exit 1
  fi

  local temp_dir=""
  local extracted_dir="$backup_item"
  if [[ "$backup_item" == *.tar.gz ]]; then
    _verify_backup_archive_checksum_if_present "$backup_item" || return 1
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$TMP_DIR" "restore temporary directory" || return 1
    fi
    temp_dir="$(mktemp -d "${TMP_DIR}/restore_XXXXXX")"
    if ! _safe_extract_tar "$backup_item" "$temp_dir"; then
      [ -n "$temp_dir" ] && rm -rf "$temp_dir"
      return 1
    fi
    local -a top_entries=()
    local entry
    while IFS= read -r -d '' entry; do
      top_entries+=("$entry")
    done < <(find "$temp_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    if [ "${#top_entries[@]}" -eq 0 ]; then
      echo "[Error] Could not find extracted directory in $temp_dir" >&2
      [ -n "$temp_dir" ] && rm -rf "$temp_dir"
      return 1
    fi
    if [ "${#top_entries[@]}" -ne 1 ] || [ ! -d "${top_entries[0]}" ]; then
      echo "[Error] Backup archive must contain a single top-level directory." >&2
      [ -n "$temp_dir" ] && rm -rf "$temp_dir"
      return 1
    fi
    extracted_dir="${top_entries[0]}"
  elif [ -d "$backup_item" ]; then
    extracted_dir="$backup_item"
  else
    echo "[Error] Unrecognized backup format (not folder or .tar.gz)." >&2
    exit 1
  fi

  if ! confirm_prompt "[Warn] Overwrite current config with backup '${backup_label}'? (y/n): "; then
    echo "[Info] Restore canceled."
    [ -n "$temp_dir" ] && rm -rf "$temp_dir"
    return
  fi

  local was_nginx_running="false"
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && ! ensure_no_nginx_container_conflict "restore-backup"; then
    [ -n "$temp_dir" ] && rm -rf "$temp_dir"
    return 1
  fi
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && nginx_container_is_managed && container_running "$NGINX_CONTAINER_NAME"; then
    was_nginx_running="true"
  fi

  if ! begin_transaction "restore_backup" "$CONFIG_DIR"; then
    [ -n "$temp_dir" ] && rm -rf "$temp_dir"
    return 1
  fi
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$CONFIG_DIR" "restore config directory" || {
      [ -n "$temp_dir" ] && rm -rf "$temp_dir"
      _rollback_handler
      return 1
    }
  fi
  ROLLBACK_RESTORE_CLEAR_DIRS="$CONFIG_DIR"
  local nginx_runtime_rollback_started=false
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
    _nginx_prepare_runtime_rollback "$NGINX_IMAGE"
    nginx_runtime_rollback_started=true
  fi

  local restored_config_dir="$extracted_dir/$(basename "$CONFIG_DIR")"
  if [ -d "$restored_config_dir" ]; then
    local clear_target clear_failed="false" clear_list_file=""
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$CONFIG_DIR" "restore config directory" || {
        [ -n "$temp_dir" ] && rm -rf "$temp_dir"
        _rollback_handler
        return 1
      }
    fi
    mkdir -p "$CONFIG_DIR"
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$CONFIG_DIR" "restore config directory" || clear_failed="true"
    fi
    if ! clear_list_file="$(mktemp "${TMP_DIR}/restore_clear_XXXXXX" 2>/dev/null)"; then
      clear_failed="true"
    elif ! find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 -print0 >"$clear_list_file" 2>/dev/null; then
      clear_failed="true"
    else
      while IFS= read -r -d '' clear_target; do
        if ! safe_rm_rf "$clear_target" "$CONFIG_DIR"; then
          clear_failed="true"
          break
        fi
      done <"$clear_list_file"
    fi
    if [ -n "$clear_list_file" ]; then
      safe_rm_f "$clear_list_file" "$TMP_DIR" || true
    fi
    if [ "$clear_failed" = "true" ]; then
      echo "[Error] Failed to clear existing config in $CONFIG_DIR before restore." >&2
      [ -n "$temp_dir" ] && rm -rf "$temp_dir"
      _rollback_handler
      return 1
    fi
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$CONFIG_DIR" "restore config directory" || {
        [ -n "$temp_dir" ] && rm -rf "$temp_dir"
        _rollback_handler
        return 1
      }
    fi
    cp -R "$restored_config_dir/." "$CONFIG_DIR/"
    echo "[Info] Restored $CONFIG_DIR in place."
  else
    echo "[Warn] Backup does not include $(basename "$CONFIG_DIR"); existing config left unchanged."
  fi

  [ -n "$temp_dir" ] && rm -rf "$temp_dir"

  echo "[Info] Normalizing restored permissions under $CONFIG_DIR."
  fix_permissions "$CONFIG_DIR"

  echo "[Info] Regenerating Nginx configuration after restore."
  update_nginx_config

  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && [ "$was_nginx_running" = "true" ]; then
    echo "[Info] Refreshing Nginx container mounts after restore."
    recreate_nginx_container "$NGINX_IMAGE"
  fi

  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && nginx_container_is_managed; then
    echo "[Info] Validating Nginx configuration after restore."
    check_config
  fi

  log_msg "Restored backup from $backup_label"
  end_transaction_success
  if [ "$nginx_runtime_rollback_started" = true ]; then
    _nginx_release_runtime_rollback
  fi
}
