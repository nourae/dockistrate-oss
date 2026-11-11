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

  local started_txn=false prep_lock_started=false mtls_dir=""
  _config_begin_runtime_prep_lock_if_needed prep_lock_started || return 1
  if ! dedicated_host_exists "$hostname" ||
    ! validate_backend_mtls_state_for_cleanup ||
    ! _removed_identity_mtls_target mtls_dir "$hostname"; then
    _config_end_runtime_prep_lock_if_started "$prep_lock_started" || true
    return 1
  fi
  local -a rollback_targets=("$CONFIG_DIR" "${CERTS_DIR}/mtls" "$mtls_dir")
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    rollback_targets+=("${DOMAINS_DIR:-${STATE_DIR}/domains}/$hostname/generated")
  fi
  if ! transaction_is_active; then
    if ! begin_transaction "remove_dedicated_host_${hostname}" "${rollback_targets[@]}"; then
      _config_end_runtime_prep_lock_if_started "$prep_lock_started" || true
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

  if backend_exists "$hostname" || alias_exists "$hostname" || dedicated_host_exists "$hostname"; then
    echo "[Info] Skipped dedicated host keyed override cleanup for '${hostname}' because another identity remains."
  else
    if ! remove_domain_keyed_render_state "$hostname"; then
      _rollback_handler
    fi
  fi
  if ! _removed_identity_cleanup_artifacts "$hostname" "$mtls_dir"; then
    _rollback_handler
  fi

  echo "[Info] Removed dedicated host '${hostname}'${target:+ (was -> ${target})}."
  log_msg "Removed dedicated host ${hostname}"
  create_backup "" "RemoveDedicatedHost_${hostname}"
  update_nginx_config
  if [ "$started_txn" = true ]; then
    end_transaction_success
  fi
}
