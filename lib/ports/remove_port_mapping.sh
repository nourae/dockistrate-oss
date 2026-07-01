# shellcheck shell=bash

_RPM_DOMAIN=""
_RPM_PORT=""
_RPM_REMOVE_TLS="false"
_RPM_PATH_REMOVED="false"

function _remove_port_mapping_rewrite_port_row_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
    [ "$STATE_BP_DOMAIN" = "${_RPM_DOMAIN:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_RPM_PORT:-}" ]; then
    if [ "$STATE_BP_PROTOCOL" = "https" ]; then
      _RPM_REMOVE_TLS="true"
    fi
    return 10
  fi
  return 0
}

function _remove_port_mapping_rewrite_path_row_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "path" ] &&
    [ "$STATE_BP_DOMAIN" = "${_RPM_DOMAIN:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_RPM_PORT:-}" ]; then
    _RPM_PATH_REMOVED="true"
    return 10
  fi
  return 0
}

function _remove_port_mapping_has_other_https_domain_on_port() {
  local removed_domain="${1:-}"
  local target_port="${2:-}"
  local shared_line="" shared_line_no=0
  local entry_type="" entry_domain="" entry_port="" entry_protocol=""

  [ -f "$BACKEND_PORTS_FILE" ] || return 1

  while IFS= read -r shared_line || [ -n "$shared_line" ]; do
    shared_line_no=$((shared_line_no + 1))
    [ "$shared_line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$shared_line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    entry_type="${STATE_BP_RECORD_TYPE:-}"
    entry_domain="${STATE_BP_DOMAIN:-}"
    entry_port="${STATE_BP_LISTEN_PORT:-}"
    entry_protocol="${STATE_BP_PROTOCOL:-}"
    [ "$entry_type" = "port" ] || continue
    [ "$entry_protocol" = "https" ] || continue
    [ "$entry_port" = "$target_port" ] || continue
    [ "$entry_domain" = "$removed_domain" ] && continue
    return 0
  done <"$BACKEND_PORTS_FILE"

  return 1
}

function remove_port_mapping() {
  local domain="${1:-}"
  local custom_port="${2:-}"
  if [ -z "$domain" ] || [ -z "$custom_port" ]; then
    echo "[Usage] remove-port <domain> <nginx_port>"
    exit 1
  fi
  require_valid_port "$custom_port"

  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi

  local -a dedicated_hosts_for_backend=()
  local dedicated_hosts_output="" dedicated_host_name=""
  if declare -F list_dedicated_hosts_for_backend >/dev/null 2>&1; then
    if ! dedicated_hosts_output="$(list_dedicated_hosts_for_backend "$domain")"; then
      echo "[Error] Failed to list dedicated hosts for backend '${domain}'." >&2
      return 1
    fi
    if [ -n "$dedicated_hosts_output" ]; then
      while IFS= read -r dedicated_host_name; do
        [ -n "$dedicated_host_name" ] || continue
        dedicated_hosts_for_backend+=("$dedicated_host_name")
      done <<<"$dedicated_hosts_output"
    fi
  fi

  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local started_txn=false
    if ! _config_begin_transaction_if_needed started_txn "remove_port_${domain}_${custom_port}"; then
      exit 1
    fi
    local remove_tls=false
    _RPM_DOMAIN="$domain"
    _RPM_PORT="$custom_port"
    _RPM_REMOVE_TLS="false"
    _RPM_PATH_REMOVED="false"

    if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _remove_port_mapping_rewrite_port_row_cb; then
      return 1
    fi
    if [ "$_RPM_REMOVE_TLS" = "true" ]; then
      remove_tls=true
    fi

    if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _remove_port_mapping_rewrite_path_row_cb; then
      return 1
    fi
    if [ "$_RPM_PATH_REMOVED" = "true" ]; then
      echo "[Info] Removed path overrides for domain=$domain on port=$custom_port."
    fi

    if declare -F nginx_directives_state_remove_for_port >/dev/null 2>&1; then
      nginx_directives_state_remove_for_port "$domain" "$custom_port" >/dev/null || true
      if [ "${#dedicated_hosts_for_backend[@]}" -gt 0 ]; then
        local dedicated_host_domain
        for dedicated_host_domain in "${dedicated_hosts_for_backend[@]}"; do
          [ -n "$dedicated_host_domain" ] || continue
          nginx_directives_state_remove_for_port "$dedicated_host_domain" "$custom_port" >/dev/null || true
        done
      fi
    fi

    if state_csv_has_row_by_keys "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" "$STATE_PORT_TLS_PROTOCOLS_COLS" 1 "$custom_port"; then
      remove_tls=true
    fi
    if state_csv_has_row_by_keys "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" "$STATE_PORT_TLS_CIPHERS_COLS" 1 "$custom_port"; then
      remove_tls=true
    fi

    if [ "$remove_tls" = true ] &&
      ! _remove_port_mapping_has_other_https_domain_on_port "$domain" "$custom_port"; then
      local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
      push_skip_update_nginx_config prev_skip_update
      remove_port_tls_protocols "$custom_port" 2>/dev/null || true
      remove_port_tls_ciphers "$custom_port" 2>/dev/null || true
      pop_skip_update_nginx_config "$prev_skip_update"
    fi

    echo "[Info] Removed port mapping for domain=$domain on port=$custom_port."
    log_msg "Removed port mapping domain=$domain port=$custom_port"
    create_backup "" "RemovePort_${domain}_${custom_port}"
    update_nginx_config
    _config_end_transaction_if_started "$started_txn"
  fi
}
# Get websocket flag for default or custom port
