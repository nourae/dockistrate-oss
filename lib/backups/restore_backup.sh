# shellcheck shell=bash

function _restore_backup_verify_settings_permissions() {
  local path="${1:-}" snapshot="" mode="" wanted=""
  local -a metadata_fields=()
  snapshot="$(_global_settings_file_snapshot "$path" || exit 1)" || return 1
  [ "$snapshot" != missing ] || return 0
  read -r -a metadata_fields <<<"$snapshot"
  mode="${metadata_fields[4]}"
  wanted="$(_permissions_intersect_mode "$mode" 640 || exit 1)" || return 1
  if [ "$mode" != "$wanted" ]; then
    echo "[Error] Restored global settings permissions are not restricted: $path" >&2
    return 1
  fi
}

function _restore_backup_prepare_runtime() {
  local config_var="${1:-}" running_var="${2:-}" extracted_dir="${3:-}" backup_ref="${4:-}"
  local restored_path="" restore_trace_state=""
  require_valid_var_name "$config_var" && require_valid_var_name "$running_var" || return 1
  restored_path="$extracted_dir/$(basename "$CONFIG_DIR")" || return 1
  if [ -L "$restored_path" ]; then
    echo "[Error] Backup config directory must not be a symlink: $restored_path" >&2
    return 1
  fi
  if [ -d "$restored_path" ]; then
    validate_persisted_config_dir "$restored_path" || return 1
    # Directory backups can retain public modes. Secure the accepted private
    # copy before runtime preparation or any live configuration publication.
    _ensure_global_settings_file_permissions_if_exists "$restored_path/global_settings.csv" || return 1
  fi
  printf -v "$config_var" '%s' "$restored_path"
  if declare -F dockistrate_prepare_runtime >/dev/null 2>&1; then
    dockistrate_prepare_runtime || return 1
    if declare -F dockistrate_start_verbose_logging >/dev/null 2>&1; then
      dockistrate_start_verbose_logging || return 1
      # Delayed startup must honor the same visibility gate as normal dispatch.
      # Disable tracing before the gate reads saved settings.
      xtrace_disable restore_trace_state || return 1
      if ! dockistrate_redacted_xtrace_needed restore-backup "$backup_ref"; then
        xtrace_restore "$restore_trace_state" || return 1
      fi
    fi
    audit_log "$(_run_command_audit_message restore-backup "$backup_ref")" || return 1
  fi
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && ! ensure_no_nginx_container_conflict "restore-backup"; then
    return 1
  fi
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && nginx_container_is_managed && container_running "$NGINX_CONTAINER_NAME"; then
    printf -v "$running_var" '%s' true
  fi
  return 0
}

function restore_backup() {
  DOCKISTRATE_RESTORE_COMPLETED=false
  local backup_ref="${1:-}" backend_details=""
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --backend-details)
      require_option_value "$@" || return 2
      backend_details="$2"
      shift 2
      ;;
    *) echo '[Usage] restore-backup <backup_name|backup_path> [--backend-details <csv>]' >&2; return 2 ;;
    esac
  done
  [ -z "$backup_ref" ] && {
    echo "[Usage] restore-backup <backup_name|backup_path> [--backend-details <csv>]"
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

  local archive_limit="" expanded_limit="" entry_limit=""
  _restore_intake_limits archive_limit expanded_limit entry_limit || return 1
  if [ ! -d "$backup_item" ] && [[ "$backup_item" != *.tar.gz ]]; then
    echo "[Error] Unrecognized backup format (not folder or .tar.gz)." >&2
    return 1
  fi
  if ! confirm_prompt "[Warn] Overwrite current config with backup '${backup_label}'? (y/n): "; then
    echo "[Info] Restore canceled."
    return 0
  fi

  # Permission normalization is mandatory after publication. Check its safe
  # metadata helper before staging or touching live state, including direct use.
  if ! declare -F _permissions_metadata_require_helper >/dev/null 2>&1; then
    # shellcheck source=../permissions/metadata_transaction.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../permissions" && pwd)/metadata_transaction.sh" || return 1
  fi
  _permissions_metadata_require_helper || return 1

  local temp_dir="" extracted_dir="" intake_status=0
  # Create only the guarded temporary parent before intake. Full runtime prep
  # can migrate settings and must wait until the candidate has been accepted.
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$TMP_DIR" "restore temporary directory" || return 1
  fi
  (umask 077; mkdir -p "$TMP_DIR") || return 1
  _backup_make_private_restore_dir temp_dir || return 1
  if _restore_intake_stage extracted_dir "$backup_item" "$temp_dir" "$archive_limit" "$expanded_limit" "$entry_limit"; then
    :
  else
    intake_status=$?
    _backup_remove_private_restore_dir "$temp_dir" || true
    return "$intake_status"
  fi

  if declare -F domain_config_backup_needs_restore >/dev/null 2>&1 &&
    { domain_config_backup_needs_restore "$extracted_dir" || [ -n "$backend_details" ]; }; then
    if _restore_intake_with_runtime_cleanup "$temp_dir" domain_config_restore_backup "$extracted_dir" "$backend_details" "$backup_ref"; then
      :
    else
      intake_status=$?
      _backup_remove_private_restore_dir "$temp_dir" || true
      return "$intake_status"
    fi
    _backup_remove_private_restore_dir "$temp_dir" || return 1
    DOCKISTRATE_RESTORE_COMPLETED=true
    return 0
  fi

  local restored_config_dir="" was_nginx_running="false"
  if ! _restore_intake_with_runtime_cleanup "$temp_dir" _restore_backup_prepare_runtime \
    restored_config_dir was_nginx_running "$extracted_dir" "$backup_ref"; then
    _backup_remove_private_restore_dir "$temp_dir" || true
    return 1
  fi

  if ! begin_transaction "restore_backup" "$CONFIG_DIR"; then
    _backup_remove_private_restore_dir "$temp_dir" || true
    return 1
  fi
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$CONFIG_DIR" "restore config directory" || {
      _backup_remove_private_restore_dir "$temp_dir" || true
      _rollback_handler
      return 1
    }
  fi
  ROLLBACK_RESTORE_CLEAR_DIRS="$CONFIG_DIR"
  local nginx_runtime_rollback_started=false
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
    if ! _nginx_prepare_runtime_rollback "$NGINX_IMAGE"; then
      _backup_remove_private_restore_dir "$temp_dir" || true
      _rollback_handler
      return 1
    fi
    nginx_runtime_rollback_started=true
  fi

  if [ -d "$restored_config_dir" ]; then
    local clear_target clear_failed="false" clear_list_file=""
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$CONFIG_DIR" "restore config directory" || {
        _backup_remove_private_restore_dir "$temp_dir" || true
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
      _backup_remove_private_restore_dir "$temp_dir" || true
      _rollback_handler
      return 1
    fi
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$CONFIG_DIR" "restore config directory" || {
        _backup_remove_private_restore_dir "$temp_dir" || true
        _rollback_handler
        return 1
      }
    fi
    # Keep the staged ceiling through publication. Ordinary copy may further
    # restrict access through umask; it must never publish broader access.
    if ! _restore_backup_verify_settings_permissions "$restored_config_dir/global_settings.csv" ||
      ! cp -R "$restored_config_dir/." "$CONFIG_DIR/" ||
      ! _restore_backup_verify_settings_permissions "$CONFIG_DIR/global_settings.csv"; then
      _backup_remove_private_restore_dir "$temp_dir" || true
      _rollback_handler
      return 1
    fi
    echo "[Info] Restored $CONFIG_DIR in place."
  else
    echo "[Warn] Backup does not include $(basename "$CONFIG_DIR"); existing config left unchanged."
  fi

  if ! _backup_remove_private_restore_dir "$temp_dir"; then
    _rollback_handler
    return 1
  fi
  temp_dir=""

  if [ -e "$GLOBAL_SETTINGS_FILE" ] || [ -L "$GLOBAL_SETTINGS_FILE" ]; then
    if ! load_config; then
      _rollback_handler
      return 1
    fi
  fi

  echo "[Info] Normalizing restored permissions under $CONFIG_DIR."
  fix_permissions "$CONFIG_DIR" || { _rollback_handler; return 1; }

  echo "[Info] Regenerating Nginx configuration after restore."
  update_nginx_config || { _rollback_handler; return 1; }

  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && [ "$was_nginx_running" = "true" ]; then
    echo "[Info] Refreshing Nginx container mounts after restore."
    recreate_nginx_container "$NGINX_IMAGE" || { _rollback_handler; return 1; }
  fi

  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && nginx_container_is_managed; then
    echo "[Info] Validating Nginx configuration after restore."
    check_config || { _rollback_handler; return 1; }
  fi

  log_msg "Restored backup from $backup_label"
  end_transaction_success || { _rollback_handler; return 1; }
  if [ "$nginx_runtime_rollback_started" = true ]; then
    _nginx_release_runtime_rollback
  fi
  # Consumed by the interactive dispatcher; canceled restores are not recorded.
  # shellcheck disable=SC2034
  DOCKISTRATE_RESTORE_COMPLETED=true
}
