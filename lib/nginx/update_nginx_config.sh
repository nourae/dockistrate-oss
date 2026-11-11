# shellcheck shell=bash

function _render_state_validation_error() {
  local line_no="${1:-0}" reason="${2:-invalid state row}"
  echo "[Error] Invalid backend_ports.csv row at line ${line_no}: ${reason}" >&2
  return 1
}

function _validate_backend_row_for_render() {
  local line_no="$1" domain="${2:-}" upstream="${3:-}" network="${4:-}"

  if ! is_valid_domain "$domain"; then
    _render_state_validation_error "$line_no" "backend domain '${domain}' is invalid"
    return 1
  fi

  if [[ "$upstream" != *:* ]]; then
    _render_state_validation_error "$line_no" "backend upstream '${upstream}' must be in ip:port format"
    return 1
  fi

  local backend_ip="${upstream%:*}" backend_port="${upstream##*:}"
  if [ -z "$backend_ip" ] || [ -z "$backend_port" ] || [ "$backend_ip" = "$upstream" ]; then
    _render_state_validation_error "$line_no" "backend upstream '${upstream}' must be in ip:port format"
    return 1
  fi

  if ! is_valid_ipv4 "$backend_ip"; then
    _render_state_validation_error "$line_no" "backend upstream IP '${backend_ip}' is invalid"
    return 1
  fi

  if ! is_valid_port "$backend_port"; then
    _render_state_validation_error "$line_no" "backend upstream port '${backend_port}' is invalid"
    return 1
  fi

  if [ -n "$network" ] && ! is_valid_network_name "$network"; then
    _render_state_validation_error "$line_no" "backend network '${network}' is invalid"
    return 1
  fi

  return 0
}

function _validate_port_row_for_render() {
  local line_no="$1" domain="${2:-}" listen_port="${3:-}" upstream_port="${4:-}" proto="${5:-}" cert_ref="${6:-}" ws="${7:-}" redirect="${8:-}" redirect_code="${9:-}" http3="${10:-}" alt_svc="${11:-}"

  if ! is_valid_domain "$domain"; then
    _render_state_validation_error "$line_no" "port domain '${domain}' is invalid"
    return 1
  fi
  if ! is_valid_port "$listen_port"; then
    _render_state_validation_error "$line_no" "listen port '${listen_port}' is invalid"
    return 1
  fi
  if ! is_valid_port "$upstream_port"; then
    _render_state_validation_error "$line_no" "upstream port '${upstream_port}' is invalid"
    return 1
  fi
  if ! is_valid_protocol "$proto"; then
    _render_state_validation_error "$line_no" "protocol '${proto}' is invalid"
    return 1
  fi

  case "$proto" in
  http | https)
    case "$ws" in
    yes | no | "") ;;
    *)
      _render_state_validation_error "$line_no" "WebSocket flag '${ws}' is invalid for protocol '${proto}'"
      return 1
      ;;
    esac
    ;;
  tcp | udp)
    case "$ws" in
    "" | no) ;;
    *)
      _render_state_validation_error "$line_no" "WebSocket flag '${ws}' is invalid for protocol '${proto}'"
      return 1
      ;;
    esac
    ;;
  esac

  if [ "$proto" = "https" ]; then
    if [ -z "$cert_ref" ] || [ "$cert_ref" = "none" ]; then
      _render_state_validation_error "$line_no" "HTTPS mapping for '${domain}:${listen_port}' requires a certificate reference"
      return 1
    fi
    local container_cert_path=""
    if ! cert_ref_to_container_dir container_cert_path "$cert_ref" || [ -z "$container_cert_path" ]; then
      _render_state_validation_error "$line_no" "certificate reference '${cert_ref}' is invalid for HTTPS mapping '${domain}:${listen_port}'"
      return 1
    fi
  else
    case "$cert_ref" in
    "" | none) ;;
    *)
      _render_state_validation_error "$line_no" "certificate reference '${cert_ref}' is not allowed for protocol '${proto}'"
      return 1
      ;;
    esac
  fi

  if [ "$proto" = "https" ]; then
    if [ -n "$http3" ] && ! is_valid_http3_flag "$http3"; then
      _render_state_validation_error "$line_no" "HTTP/3 flag '${http3}' is invalid for HTTPS mapping '${domain}:${listen_port}'"
      return 1
    fi
    if [ -n "$alt_svc" ] && ! is_valid_alt_svc_mode "$alt_svc"; then
      _render_state_validation_error "$line_no" "Alt-Svc value '${alt_svc}' is invalid for HTTPS mapping '${domain}:${listen_port}'"
      return 1
    fi
  else
    case "$http3" in
    "" | off) ;;
    *)
      _render_state_validation_error "$line_no" "HTTP/3 flag '${http3}' is only valid for HTTPS mappings"
      return 1
      ;;
    esac
    case "$alt_svc" in
    "" | auto) ;;
    *)
      _render_state_validation_error "$line_no" "Alt-Svc value '${alt_svc}' is only valid for HTTPS mappings"
      return 1
      ;;
    esac
  fi

  case "$proto" in
  http)
    if ! validate_http_port_combination "$proto" "$listen_port"; then
      _render_state_validation_error "$line_no" "HTTP protocol is not allowed on port 443"
      return 1
    fi
    case "$redirect" in
    on | off | "") ;;
    *)
      _render_state_validation_error "$line_no" "redirect flag '${redirect}' is invalid for HTTP mapping '${domain}:${listen_port}'"
      return 1
      ;;
    esac
    if [ "$redirect" = "on" ]; then
      # Blank selects the renderer's 301 default; explicit codes remain strict.
      if [ -n "$redirect_code" ] && ! is_valid_redirect_code_spec "$redirect_code"; then
        _render_state_validation_error "$line_no" "redirect code '${redirect_code}' is invalid for HTTP mapping '${domain}:${listen_port}'"
        return 1
      fi
    elif [ -n "$redirect_code" ]; then
      _render_state_validation_error "$line_no" "redirect code '${redirect_code}' requires redirect flag 'on' for HTTP mapping '${domain}:${listen_port}'"
      return 1
    fi
    ;;
  https | tcp | udp)
    case "$redirect" in
    "" | off) ;;
    *)
      _render_state_validation_error "$line_no" "redirect flag '${redirect}' is invalid for protocol '${proto}'"
      return 1
      ;;
    esac
    if [ -n "$redirect_code" ]; then
      _render_state_validation_error "$line_no" "redirect code '${redirect_code}' is not allowed for protocol '${proto}'"
      return 1
    fi
    ;;
  esac

  return 0
}

function _validate_path_row_for_render() {
  local line_no="$1" domain="${2:-}" path_prefix="${3:-}" header_set="${4:-}" listen_port="${5:-}" ws="${6:-}" redirect="${7:-}" redirect_code="${8:-}" match_mode="${9:-}" priority="${10:-}" target="${11:-}" rewrite="${12:-}" reason="${13:-}" loc="${14:-}"

  if ! is_valid_domain "$domain"; then
    _render_state_validation_error "$line_no" "path domain '${domain}' is invalid"
    return 1
  fi
  if ! is_valid_port "$listen_port"; then
    _render_state_validation_error "$line_no" "path listen port '${listen_port}' is invalid"
    return 1
  fi

  if declare -F is_valid_path_prefix >/dev/null 2>&1; then
    if ! is_valid_path_prefix "$path_prefix"; then
      _render_state_validation_error "$line_no" "unsafe path prefix '${path_prefix}'"
      return 1
    fi
  elif [[ "$path_prefix" != /* ]]; then
    _render_state_validation_error "$line_no" "unsafe path prefix '${path_prefix}'"
    return 1
  fi

  if [ -n "$header_set" ]; then
    if declare -F is_valid_header_set_name >/dev/null 2>&1; then
      if ! is_valid_header_set_name "$header_set"; then
        _render_state_validation_error "$line_no" "path header set '${header_set}' is invalid"
        return 1
      fi
    elif [[ ! "$header_set" =~ ^[-A-Za-z0-9_]+$ ]]; then
      _render_state_validation_error "$line_no" "path header set '${header_set}' is invalid"
      return 1
    fi
  fi

  case "$ws" in
  "" | yes | no | inherit) ;;
  *)
    _render_state_validation_error "$line_no" "path WebSocket override '${ws}' is invalid"
    return 1
    ;;
  esac

  case "$redirect" in
  "" | on | off | inherit) ;;
  *)
    _render_state_validation_error "$line_no" "path redirect override '${redirect}' is invalid"
    return 1
    ;;
  esac

  if [ "$redirect" = "on" ]; then
    # Resolve blank codes during rendering so paths keep following their listener.
    if [ -n "$redirect_code" ] && ! is_valid_redirect_code_spec "$redirect_code"; then
      _render_state_validation_error "$line_no" "path redirect code '${redirect_code}' is invalid"
      return 1
    fi
  elif [ -n "$redirect_code" ]; then
    _render_state_validation_error "$line_no" "path redirect code '${redirect_code}' requires redirect override 'on'"
    return 1
  fi

  if ! is_valid_path_match_mode "${match_mode:-prefix}"; then
    _render_state_validation_error "$line_no" "path match mode '${match_mode}' is invalid"
    return 1
  fi

  if ! is_valid_path_priority "${priority:-100}"; then
    _render_state_validation_error "$line_no" "path priority '${priority}' is invalid"
    return 1
  fi

  if [ -n "$target" ] && ! is_valid_path_target "$target"; then
    _render_state_validation_error "$line_no" "path target '${target}' is invalid"
    return 1
  fi

  if ! is_valid_path_rewrite_spec "${rewrite:-none}"; then
    _render_state_validation_error "$line_no" "path rewrite '${rewrite}' is invalid"
    return 1
  fi

  if ! is_valid_reason_value "${reason:--}"; then
    _render_state_validation_error "$line_no" "path reason '${reason}' is invalid"
    return 1
  fi

  if ! is_valid_loc_value "${loc:-auto}"; then
    _render_state_validation_error "$line_no" "path loc '${loc}' is invalid"
    return 1
  fi

  return 0
}

function _validate_backend_ports_state_for_render() {
  [ -f "$BACKEND_PORTS_FILE" ] || return 0
  if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    return 1
  fi

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      continue
    fi
    if ! csv_parse_line "$line"; then
      _render_state_validation_error "$line_no" "row could not be parsed as CSV (${CSV_PARSE_ERROR})"
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_PORTS_COLS" ]; then
      _render_state_validation_error "$line_no" "row has invalid column count (expected ${STATE_BACKEND_PORTS_COLS}, got ${CSV_FIELD_COUNT})"
      return 1
    fi
    if ! state_backend_ports_assign_from_fields; then
      _render_state_validation_error "$line_no" "row could not be mapped to backend schema"
      return 1
    fi

    case "$STATE_BP_RECORD_TYPE" in
    backend)
      if ! _validate_backend_row_for_render "$line_no" "$STATE_BP_DOMAIN" "$STATE_BP_BACKEND_UPSTREAM" "$STATE_BP_NETWORK"; then
        return 1
      fi
      ;;
    port)
      if ! _validate_port_row_for_render "$line_no" "$STATE_BP_DOMAIN" "$STATE_BP_LISTEN_PORT" "$STATE_BP_UPSTREAM_PORT" "$STATE_BP_PROTOCOL" "$STATE_BP_CERT_REF" "$STATE_BP_WS" "$STATE_BP_REDIRECT_FLAG" "$STATE_BP_REDIRECT_CODE" "$STATE_BP_HTTP3" "$STATE_BP_ALT_SVC"; then
        return 1
      fi
      ;;
    path)
      if ! _validate_path_row_for_render "$line_no" "$STATE_BP_DOMAIN" "$STATE_BP_PATH_PREFIX" "$STATE_BP_HEADER_SET" "$STATE_BP_LISTEN_PORT" "$STATE_BP_WS" "$STATE_BP_REDIRECT_FLAG" "$STATE_BP_REDIRECT_CODE" "$STATE_BP_PATH_MATCH" "$STATE_BP_PATH_PRIORITY" "$STATE_BP_PATH_TARGET" "$STATE_BP_PATH_REWRITE" "$STATE_BP_REASON" "$STATE_BP_LOC"; then
        return 1
      fi
      ;;
    "")
      _render_state_validation_error "$line_no" "row type is empty"
      return 1
      ;;
    *)
      _render_state_validation_error "$line_no" "unknown row type '${STATE_BP_RECORD_TYPE:-}'"
      return 1
      ;;
    esac
  done <"$BACKEND_PORTS_FILE"

  return 0
}

function _render_backend_upstream_for_domain() {
  local domain="${1:-}" line="" line_no=0
  domain="$(normalize_domain "$domain")"
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
    if [ "$STATE_BP_RECORD_TYPE" = "backend" ] && [ "$(normalize_domain "$STATE_BP_DOMAIN")" = "$domain" ]; then
      printf '%s\n' "$STATE_BP_BACKEND_UPSTREAM"
      return 0
    fi
  done <"$BACKEND_PORTS_FILE"

  return 1
}

function _http3_alt_svc_header_line() {
  local listen_port="${1:-}" alt_svc_mode="${2:-auto}"
  local alt_svc_value=""

  case "$alt_svc_mode" in
  off)
    return 0
    ;;
  auto | "")
    alt_svc_value="h3=\":${listen_port}\"; ma=86400"
    ;;
  *)
    alt_svc_value="$alt_svc_mode"
    ;;
  esac

  if declare -F _escape_header_value >/dev/null 2>&1; then
    alt_svc_value="$(_escape_header_value "$alt_svc_value")"
  fi
  printf '    add_header Alt-Svc "%s" always;\n' "$alt_svc_value"
}

function _nginx_wait_for_security_update_ready() {
  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    return 0
  fi

  if ! nginx_container_is_managed || ! container_running "$NGINX_CONTAINER_NAME"; then
    echo "[Error] Nginx container is not running after security config update." >&2
    return 1
  fi

  local attempts="${DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS:-20}" attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if docker exec "$NGINX_CONTAINER_NAME" nginx -t -c "$NGINX_CONTAINER_MAIN_CONF" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1 2>/dev/null || sleep 1
    attempt=$((attempt + 1))
  done

  echo "[Error] Nginx did not pass config readiness checks after security config update." >&2
  return 1
}

function update_nginx_config() {
  if [ "${SKIP_UPDATE_NGINX_CONFIG:-}" = "true" ]; then
    return 0
  fi
  if [ "${DOMAIN_CONFIG_DEFER_RENDER:-false}" = true ]; then
    DOMAIN_CONFIG_RENDER_REQUESTED=true
    if [ "${DOCKISTRATE_FORCE_NGINX_RECREATE:-false}" = true ] ||
      [ "${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-false}" = true ]; then
      DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE=true
    fi
    return 0
  fi
  _with_validated_render_settings _update_nginx_config_from_validated_settings
}

function _update_nginx_config_from_validated_settings() {
  if ! _persisted_settings_cache_in_scope || [ "${_persisted_cache_ready:-false}" != true ]; then
    echo "[Error] Config generation requires validated persisted settings." >&2
    return 1
  fi
  local deferred_security_recreate="${DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE:-false}"
  local security_ready_check="${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-false}"
  unset DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE
  unset DOCKISTRATE_SECURITY_NGINX_READY_CHECK
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && ! ensure_no_nginx_container_conflict "update-nginx-config"; then
    return 1
  fi
  local config_file="${NGINX_HTTP_CONF_DIR}/backends.conf"
  local stream_file="${NGINX_STREAM_CONF_DIR}/streams.conf"
  local started_txn=false
  # Avoid clobbering variables in caller scopes
  local domain upstream net name custom_port upstream_port
  local proto cert_path ws listen listen_port target_port port_http3 port_alt_svc
  if ! transaction_is_active; then
    if ! begin_transaction "nginx_update" "$CONFIG_DIR"; then
      return 1
    fi
    started_txn=true
  fi
  if [ -d "${NGINX_CONFIG_DIR}/nginx.conf" ]; then
    echo "[Warn] Expected file but found directory at ${NGINX_CONFIG_DIR}/nginx.conf; regenerating." >&2
    rm -rf "${NGINX_CONFIG_DIR}/nginx.conf"
  fi
  if [ ! -f "${NGINX_CONFIG_DIR}/nginx.conf" ]; then
    if ! create_nginx_config; then
      _rollback_handler
    fi
  elif declare -F validate_access_log_fields_state_for_render >/dev/null 2>&1; then
    if ! validate_access_log_fields_state_for_render; then
      _rollback_handler
    fi
  fi
  # Guarantee include files exist even if no rules configured
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "${NGINX_HTTP_CONF_DIR}" "${NGINX_STREAM_CONF_DIR}" "${SECURITY_IP_DIR}" "${SECURITY_IP_STREAM_DIR}" "$PATH_HEADER_DIR" || return 1
  fi
  mkdir -p "${NGINX_HTTP_CONF_DIR}"
  mkdir -p "${NGINX_STREAM_CONF_DIR}"
  mkdir -p "${SECURITY_IP_DIR}" "${SECURITY_IP_STREAM_DIR}"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared \
      "${NGINX_HTTP_CONF_DIR}" \
      "${NGINX_STREAM_CONF_DIR}" \
      "${SECURITY_IP_DIR}" \
      "${SECURITY_IP_STREAM_DIR}" \
      "$PATH_HEADER_DIR" \
      "${NGINX_HTTP_CONF_DIR}/custom_headers.conf" \
      "${NGINX_HTTP_CONF_DIR}/backend_headers.conf" \
      "${NGINX_HTTP_CONF_DIR}/backend_header_maps.conf" || return 1
  fi
  touch "${NGINX_HTTP_CONF_DIR}/custom_headers.conf" "${NGINX_HTTP_CONF_DIR}/backend_headers.conf" \
    "${NGINX_HTTP_CONF_DIR}/backend_header_maps.conf"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$PATH_HEADER_DIR" "path header include directory" || return 1
  fi
  mkdir -p "$PATH_HEADER_DIR"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$PATH_HEADER_DIR" "path header include directory" || return 1
  fi
  # Ensure stored networks and IPs match running containers before generating configs
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
    # Network refresh also refreshes IPs from that same verified snapshot.
    if ! refresh_backend_networks; then
      _rollback_handler
      return 1
    fi
  fi
  if ! _validate_backend_ports_state_for_render; then
    _rollback_handler
  fi
  if declare -F validate_backend_aliases_state_for_render >/dev/null 2>&1; then
    if ! validate_backend_aliases_state_for_render; then
      _rollback_handler
    fi
  fi
  if declare -F validate_backend_mtls_state_for_render >/dev/null 2>&1; then
    if ! validate_backend_mtls_state_for_render; then
      _rollback_handler
    fi
  fi
  if ! build_security_rules_inc; then
    _rollback_handler
  fi
  if declare -F validate_tls_settings_for_render >/dev/null 2>&1; then
    if ! validate_tls_settings_for_render; then
      _rollback_handler
    fi
  fi
  if ! _build_header_files; then
    _rollback_handler
  fi
  # Always recreate the default config to ensure the ACME challenge
  # location exists. Older installations may lack this block, which
  # breaks webroot certificate generation.
  if ! fix_default_config; then
    _rollback_handler
  fi
  if declare -F nginx_directives_validate_for_render >/dev/null 2>&1; then
    if ! nginx_directives_validate_for_render; then
      _rollback_handler
    fi
  fi
  if declare -F nginx_directives_render_global_include >/dev/null 2>&1; then
    if ! nginx_directives_render_global_include; then
      _rollback_handler
    fi
  fi
  if declare -F nginx_directives_render_stream_global_include >/dev/null 2>&1; then
    if ! nginx_directives_render_stream_global_include; then
      _rollback_handler
    fi
  fi
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$config_file" "$stream_file" || return 1
  fi
  echo "# Auto-generated config" >"${config_file}"
  echo "include ${NGINX_CONTAINER_HTTP_CONF_DIR}/backend_header_maps.conf;" >>"${config_file}"
  echo "# Auto-generated stream config" >"$stream_file"
  if declare -F _domain_config_render_begin >/dev/null 2>&1; then
    _domain_config_render_begin || return 1
  fi
  if declare -F domain_config_active >/dev/null 2>&1 &&
    { domain_config_active || [ "${DOMAIN_CONFIG_ACTIVE:-false}" = true ]; }; then
    printf '%s\n' 'upstream dockistrate_unavailable { server 127.0.0.1:1 down; }' >>"$config_file" || return 1
    printf '%s\n' 'upstream dockistrate_unavailable { server 127.0.0.1:1 down; }' >>"$stream_file" || return 1
  fi

  # Check if any port mappings exist before generating configs
  local has_port_mappings=false
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local state_line="" state_line_no=0
    while IFS= read -r state_line || [ -n "$state_line" ]; do
      state_line_no=$((state_line_no + 1))
      [ "$state_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$state_line" || _rollback_handler
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || _rollback_handler
      if [ "$STATE_BP_RECORD_TYPE" = "port" ]; then
        has_port_mappings=true
        break
      fi
    done <"$BACKEND_PORTS_FILE"
  fi

  if [ "$has_port_mappings" = false ]; then
    echo "# No backends configured yet." >>"$config_file"
  else
    # Port mappings (HTTP/HTTPS/TCP)
    # Only HTTP/HTTPS ports in HTTP config; TCP handled in stream config below
    state_line_no=0
    while IFS= read -r state_line || [ -n "$state_line" ]; do
      state_line_no=$((state_line_no + 1))
      [ "$state_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$state_line" || _rollback_handler
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || _rollback_handler
      [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
      [ "$STATE_BP_PROTOCOL" = "tcp" ] && continue
      [ "$STATE_BP_PROTOCOL" = "udp" ] && continue

      domain="$(normalize_domain "$STATE_BP_DOMAIN")"
      custom_port="$STATE_BP_LISTEN_PORT"
      upstream_port="$STATE_BP_UPSTREAM_PORT"
      proto="$STATE_BP_PROTOCOL"
      cert_path="$STATE_BP_CERT_REF"
      ws="$STATE_BP_WS"
      redirect="$STATE_BP_REDIRECT_FLAG"
      code="$STATE_BP_REDIRECT_CODE"
      port_http3="${STATE_BP_HTTP3:-off}"
      port_alt_svc="${STATE_BP_ALT_SVC:-auto}"
      [ -n "$domain" ] || continue
      local alias_names plain_aliases="" explicit_acl_aliases="" alias_name alias_acl_status
      alias_names="$(list_domain_aliases "$domain")" || { _rollback_handler; return 1; }
      for alias_name in $alias_names; do
        if _alias_has_explicit_acl "$alias_name"; then
          explicit_acl_aliases="${explicit_acl_aliases}${explicit_acl_aliases:+ }${alias_name}"
        else
          alias_acl_status=$?
          if [ "$alias_acl_status" -ne 1 ]; then
            _rollback_handler
            return 1
          fi
          plain_aliases="${plain_aliases}${plain_aliases:+ }${alias_name}"
        fi
      done
      local server_names="$domain"
      [ -n "$plain_aliases" ] && server_names+=" $plain_aliases"

      local base_upstream
      base_upstream="$(_render_backend_upstream_for_domain "$domain" || true)"
      [ -z "$base_upstream" ] && continue
      local container_ip
      container_ip="${base_upstream%%:*}"
      local final_upstream="${container_ip}:${upstream_port}"
      if declare -F domain_config_backend_stopped >/dev/null 2>&1 && domain_config_backend_stopped "$domain"; then
        final_upstream=dockistrate_unavailable
      fi

      if ! _emit_backend_server_block "$config_file" "$domain" "$server_names" "$plain_aliases" "$domain" \
        "$custom_port" "$final_upstream" "$proto" "$cert_path" "$ws" "$redirect" "$code" "$port_http3" "$port_alt_svc"; then
        _rollback_handler
        return 1
      fi
      for alias_name in $explicit_acl_aliases; do
        if ! _emit_backend_server_block "$config_file" "$domain" "$alias_name" "$alias_name" "$alias_name" \
          "$custom_port" "$final_upstream" "$proto" "$cert_path" "$ws" "$redirect" "$code" "$port_http3" "$port_alt_svc"; then
          _rollback_handler
          return 1
        fi
      done

      # Generate separate server blocks for dedicated hosts
      local dedicated_hosts
      dedicated_hosts="$(list_dedicated_hosts_for_backend "$domain")"
      if [ -n "$dedicated_hosts" ]; then
        local dh
        for dh in $dedicated_hosts; do
          if ! _emit_dedicated_host_server_block "$config_file" "$dh" "$domain" "$custom_port" "$upstream_port" "$proto" "$cert_path" "$ws" "$redirect" "$code" "$port_http3" "$port_alt_svc"; then
            _rollback_handler
          fi
        done
      fi
    done <"$BACKEND_PORTS_FILE"

    # TCP stream mappings from unified port records
    state_line_no=0
    while IFS= read -r state_line || [ -n "$state_line" ]; do
      state_line_no=$((state_line_no + 1))
      [ "$state_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$state_line" || _rollback_handler
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || _rollback_handler
      [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
      [ "$STATE_BP_PROTOCOL" = "tcp" ] || [ "$STATE_BP_PROTOCOL" = "udp" ] || continue

      domain="$(normalize_domain "$STATE_BP_DOMAIN")"
      listen_port="$STATE_BP_LISTEN_PORT"
      target_port="$STATE_BP_UPSTREAM_PORT"
      proto="$STATE_BP_PROTOCOL"
      base_upstream="$(_render_backend_upstream_for_domain "$domain" || true)"
      [ -z "$base_upstream" ] && continue
      container_ip="${base_upstream%%:*}"
      local domain_stream_first_line
      domain_stream_first_line=$(( $(wc -l <"$stream_file") + 1 ))
      final_upstream="${container_ip}:${target_port}"
      if declare -F domain_config_backend_stopped >/dev/null 2>&1 && domain_config_backend_stopped "$domain"; then
        final_upstream=dockistrate_unavailable
      fi
      cat >>"$stream_file" <<EOF
server {
    listen ${listen_port}$([ "$proto" = "udp" ] && echo " udp");
    include ${NGINX_CONTAINER_STREAM_CONF_DIR}/security_ip/$(sanitize_domain_name "$domain").inc;
    # security_ip include above covers stream ACLs
EOF
      if declare -F nginx_directives_render_stream_server_directives >/dev/null 2>&1; then
        if ! nginx_directives_render_stream_server_directives "$stream_file" "$domain" "$listen_port"; then
          _rollback_handler
        fi
      fi
      cat >>"$stream_file" <<EOF
    proxy_pass ${final_upstream};
}
EOF
      if declare -F _domain_config_capture_stream >/dev/null 2>&1; then
        _domain_config_capture_stream "$domain" "$stream_file" "$domain_stream_first_line" || return 1
      fi
    done <"$BACKEND_PORTS_FILE"
  fi

  echo "[Info] Nginx configuration updated."
  log_msg "Nginx config updated from $BACKEND_PORTS_FILE."

  local nginx_runtime_rollback_started=false
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
    local nginx_certificate_projection=""
    if ! declare -F _nginx_prepare_certificate_projection >/dev/null 2>&1; then
      # shellcheck source=lib/nginx/certificate_projection.sh
      source "${BASH_SOURCE[0]%/*}/certificate_projection.sh" || return 1
    fi
    if ! _nginx_prepare_certificate_projection nginx_certificate_projection; then
      _rollback_handler
      return 1
    fi
    if declare -F domain_config_validate_nginx_candidate >/dev/null 2>&1 &&
      ! domain_config_validate_nginx_candidate "$nginx_certificate_projection"; then
      _rollback_handler
      return 1
    fi
    local new_bindings current_bindings recreated=false
    local force_recreate="${DOCKISTRATE_FORCE_NGINX_RECREATE:-false}"
    if [ "$deferred_security_recreate" = "true" ]; then
      force_recreate=true
      security_ready_check=true
    fi
    new_bindings="$(get_all_mapped_port_bindings | tr ' ' '\n' | sort -u | xargs)"
    if nginx_container_is_managed; then
      if ! _nginx_container_has_certificate_projection "$nginx_certificate_projection" 2>/dev/null; then
        force_recreate=true
        security_ready_check=true
      fi
      current_bindings="$(container_published_port_bindings "$NGINX_CONTAINER_NAME" | xargs)"
      if [ "$force_recreate" = "true" ] || [ "$current_bindings" != "$new_bindings" ] || ! container_running "$NGINX_CONTAINER_NAME"; then
        _nginx_prepare_runtime_rollback "$NGINX_IMAGE"
        nginx_runtime_rollback_started=true
        if ! recreate_nginx_container "$NGINX_IMAGE" "$new_bindings" "$nginx_certificate_projection"; then
          _rollback_handler
        fi
        recreated=true
      fi
    else
      security_ready_check=true
      _nginx_prepare_runtime_rollback "$NGINX_IMAGE"
      nginx_runtime_rollback_started=true
      if ! recreate_nginx_container "$NGINX_IMAGE" "$new_bindings" "$nginx_certificate_projection"; then
        _rollback_handler
      fi
      recreated=true
    fi

    if [ "$recreated" != true ]; then
      _nginx_prepare_runtime_rollback "$NGINX_IMAGE" || return 1
      nginx_runtime_rollback_started=true
    fi
    # Network reconciliation can detach a live upstream before reload. Record
    # the recovery intent before either runtime mutation can take effect.
    _nginx_mark_runtime_rollback_needed || return 1
    if ! add_nginx_networks; then
      echo "[Error] Failed to attach Nginx to required backend networks. Rolling back." >&2
      _rollback_handler
    fi
    remove_unused_nginx_networks
    if [ "$recreated" != "true" ]; then
      # A reload can apply new effective config before an outer commit fails,
      # even if certificate bytes and their mounted generation are unchanged.
      if ! reload_nginx_if_running; then
        echo "[Error] Nginx reload failed after config update. Rolling back." >&2
        _rollback_handler
      fi
    fi

    if ! nginx_container_is_managed || ! container_running "$NGINX_CONTAINER_NAME"; then
      echo "[Error] Nginx container failed to start after config update. Rolling back." >&2
      _rollback_handler
    fi
    if [ "$security_ready_check" = "true" ]; then
      if ! _nginx_wait_for_security_update_ready; then
        _rollback_handler
      fi
    fi
    # Retire unmounted snapshots only after the replacement is validated. This
    # remains within the enclosing CONFIG_DIR transaction, so later failures
    # restore the prior generations before the runtime rollback hook recreates.
    if ! _nginx_container_has_certificate_projection "$nginx_certificate_projection"; then
      echo "[Error] Nginx certificate mount changed before projection retirement. Rolling back." >&2
      _rollback_handler
      return 1
    fi
    if ! _nginx_prune_certificate_projections "$nginx_certificate_projection"; then
      _rollback_handler
      return 1
    fi
  else
    echo "[Info] SKIP_DOCKER_CHECKS=true: generated config files only (no container changes)."
  fi

  if declare -F _domain_config_render_complete >/dev/null 2>&1; then
    _domain_config_render_complete || return 1
  fi
  if [ "$started_txn" = true ]; then
    end_transaction_success
  fi
  if [ "$nginx_runtime_rollback_started" = true ]; then
    _nginx_release_runtime_rollback
  fi
}
