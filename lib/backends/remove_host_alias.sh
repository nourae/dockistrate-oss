# shellcheck shell=bash
function remove_host_alias() {
  local alias="${1:-}"
  if [ -z "$alias" ]; then
    echo "[Usage] remove-host-alias <alias>"
    exit 1
  fi

  alias="$(normalize_domain "$alias")"

  if ! alias_exists "$alias"; then
    echo "[Error] Alias '$alias' not found." >&2
    exit 1
  fi

  local aliases_file
  local target
  target="$(backend_for_alias "$alias")"
  aliases_file="$(backend_aliases_file)"
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_alias_${alias}"; then
    exit 1
  fi
  if ! state_csv_delete_by_keys "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" 2 "alias" "$alias"; then
    _rollback_handler
    return 1
  fi
  # Removing/recreating a name must not silently resurrect its old ACL. Preserve
  # another identity's state when repairing an invalid, colliding alias row.
  if ! _state_helpers_validate_backend_ports_readable_for_cleanup; then
    _rollback_handler
    return 1
  fi
  if ! backend_exists "$alias" && ! dedicated_host_exists "$alias"; then
    if ! remove_domain_keyed_render_state "$alias" ||
      ! safe_rm_f "${SECURITY_IP_DIR}/$(sanitize_domain_name "$alias").inc" "$SECURITY_IP_DIR" ||
      ! safe_rm_f "${SECURITY_IP_STREAM_DIR}/$(sanitize_domain_name "$alias").inc" "$SECURITY_IP_STREAM_DIR"; then
      _rollback_handler
      return 1
    fi
  fi
  echo "[Info] Removed host alias '${alias}'${target:+ (was -> ${target})}."
  log_msg "Removed host alias ${alias}"
  if ! create_backup "" "RemoveAlias_${alias}" || ! update_nginx_config_for_security_change ||
    ! _config_end_transaction_if_started "$started_txn"; then
    _rollback_handler
    return 1
  fi
}
