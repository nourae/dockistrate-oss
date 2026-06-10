# shellcheck shell=bash
function remove_dedicated_host() {
  local hostname="${1:-}"
  if [ -z "$hostname" ]; then
    echo "[Usage] remove-dedicated-host <hostname>"
    exit 1
  fi

  hostname="$(normalize_domain "$hostname")"

  if ! dedicated_host_exists "$hostname"; then
    echo "[Error] Dedicated host '$hostname' not found." >&2
    exit 1
  fi

  local target
  target="$(backend_for_dedicated_host "$hostname" 2>/dev/null || true)"

  local started_txn=false
  if ! transaction_is_active; then
    if ! begin_transaction "remove_dedicated_host_${hostname}" "$CONFIG_DIR"; then
      return 1
    fi
    started_txn=true
  fi
  if ! remove_dedicated_host_alias "$hostname"; then
    _rollback_handler
  fi

  # Clean up inheritance settings
  if ! remove_dedicated_host_inheritance "$hostname"; then
    _rollback_handler
  fi

  if declare -F _state_helpers_validate_backend_ports_readable_for_cleanup >/dev/null 2>&1; then
    if ! _state_helpers_validate_backend_ports_readable_for_cleanup; then
      _rollback_handler
    fi
  fi

  if backend_exists "$hostname"; then
    echo "[Info] Skipped dedicated host keyed override cleanup for '${hostname}' because it is also an existing backend domain."
  else
    if ! remove_domain_keyed_render_state "$hostname"; then
      _rollback_handler
    fi
  fi

  echo "[Info] Removed dedicated host '${hostname}'${target:+ (was -> ${target})}."
  log_msg "Removed dedicated host ${hostname}"
  create_backup "" "RemoveDedicatedHost_${hostname}"
  update_nginx_config
  if [ "$started_txn" = true ]; then
    end_transaction_success
  fi
}
