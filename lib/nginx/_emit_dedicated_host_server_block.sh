# shellcheck shell=bash

# Generate an nginx server block for a dedicated host
# Arguments:
#   $1 - config_file to append to
#   $2 - dedicated_host hostname
#   $3 - target_domain (the backend domain it proxies to)
#   $4 - custom_port
#   $5 - upstream_port
#   $6 - proto (http/https)
#   $7 - cert_path
#   $8 - ws (websocket flag)
#   $9 - redirect
#   $10 - code (redirect status code)
#   $11 - http3 (on|off)
#   $12 - alt_svc (auto|off|custom)
function _emit_dedicated_host_server_block() {
  local config_file="$1"
  local dedicated_host="$2"
  local target_domain="$3"
  local custom_port="$4"
  local upstream_port="$5"
  local proto="$6"
  local cert_path="$7"
  local ws="$8"
  local redirect="$9"
  local code="${10:-}"
  local http3="${11:-off}"
  local alt_svc="${12:-auto}"

  dedicated_host="$(normalize_domain "$dedicated_host")"
  target_domain="$(normalize_domain "$target_domain")"
  if ! is_valid_domain "$dedicated_host"; then
    echo "[Error] Invalid dedicated host render input: hostname '${dedicated_host}' is invalid." >&2
    return 1
  fi
  if ! is_valid_domain "$target_domain"; then
    echo "[Error] Invalid dedicated host render input: target domain '${target_domain}' is invalid." >&2
    return 1
  fi
  if ! backend_exists "$target_domain"; then
    echo "[Error] Invalid dedicated host render input: target backend '${target_domain}' does not exist." >&2
    return 1
  fi
  local configured_target
  configured_target="$(backend_for_dedicated_host "$dedicated_host" || true)"
  if [ "$configured_target" != "$target_domain" ]; then
    echo "[Error] Invalid dedicated host render input: '${dedicated_host}' is not registered for '${target_domain}'." >&2
    return 1
  fi

  local base_upstream line="" line_no=0
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
      return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || return 1
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
      if [ "$STATE_BP_RECORD_TYPE" = "backend" ] && [ "$(normalize_domain "$STATE_BP_DOMAIN")" = "$target_domain" ]; then
        base_upstream="$STATE_BP_BACKEND_UPSTREAM"
        break
      fi
    done <"$BACKEND_PORTS_FILE"
  fi
  if [ -z "$base_upstream" ]; then
    echo "[Error] Failed to find backend row for dedicated host target '${target_domain}'." >&2
    return 1
  fi

  local container_ip
  container_ip="$(echo "$base_upstream" | cut -d':' -f1)"
  local final_upstream="${container_ip}:${upstream_port}"

  # Use the dedicated host's own configuration for ACL, mTLS, headers, etc.
  # This allows each dedicated host to have independent settings with fallback to target domain
  local dedicated_http_ver
  dedicated_http_ver="$(get_backend_http_version "$dedicated_host")"
  # Fall back to target domain's HTTP version if not set for dedicated host
  [ -z "$dedicated_http_ver" ] && dedicated_http_ver="$(get_backend_http_version "$target_domain")"

  cat >>"$config_file" <<EOF

# Dedicated host mapping for $dedicated_host:$custom_port => $final_upstream (via $target_domain)
# Inherits config from $target_domain when not explicitly overridden
EOF

  # IP header lookup already handles dedicated-host inheritance and explicit off semantics.
  local cip pip realip_lines
  cip="$(get_backend_client_ip_header "$dedicated_host")"
  pip="$(get_backend_proxy_ip_header "$dedicated_host")"
  if ! realip_lines="$(_real_ip_directives "$cip")"; then
    return 1
  fi

  local proxy_http_version
  proxy_http_version="$(get_proxy_http_version "$dedicated_host")"
  [ -z "$proxy_http_version" ] && proxy_http_version="$(get_proxy_http_version "$target_domain")"

  # Build proxy header lines (shared between HTTP and HTTPS blocks)
  local pip_line=""
  if [ -n "$pip" ]; then
    if [ -n "$realip_lines" ]; then
      pip_line="        proxy_set_header ${pip} \$realip_remote_addr;"
    else
      pip_line="        proxy_set_header ${pip} \$remote_addr;"
    fi
  fi
  local cip_line=""
  if [ -n "$cip" ]; then
    local cip_val
    cip_val=$(_client_ip_value_var "$cip")
    cip_line="        proxy_set_header ${cip} ${cip_val};"
  fi

  local sanitized_host
  sanitized_host="$(sanitize_domain_name "${dedicated_host}")"
  local header_identity_lines
  header_identity_lines="$(_backend_header_identity_directives "$dedicated_host")"

  if [ "$proto" == "https" ]; then
    local container_cert_path
    if ! cert_ref_to_container_dir container_cert_path "$cert_path"; then
      echo "[Error] Failed to resolve certificate directory for dedicated host '${dedicated_host}'." >&2
      return 1
    fi
    if [ -z "$container_cert_path" ]; then
      echo "[Error] Empty certificate directory for dedicated host '${dedicated_host}'." >&2
      return 1
    fi
    local listen_port="${custom_port}"
    local tls_protos tls_ciphers
    tls_protos="$(get_port_tls_protocols "$listen_port")"
    tls_ciphers="$(get_port_tls_ciphers "$listen_port")"
    local mtls_directives
    if ! mtls_directives="$(_backend_mtls_directives "$dedicated_host")"; then
      echo "[Error] Failed to render mTLS directives for dedicated host '${dedicated_host}' on port '${custom_port}'." >&2
      return 1
    fi

    # Security IP include uses the dedicated host's own rules (with fallback to target domain)
    cat >>"$config_file" <<EOF
server {
    listen ${custom_port} ssl;
    server_name ${dedicated_host};
${header_identity_lines}
${realip_lines}
    include ${NGINX_CONTAINER_HTTP_CONF_DIR}/security_ip/${sanitized_host}.inc;
    # security_ip include covers both L7 and L3 policies
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =444;
    }
$([ "$dedicated_http_ver" = "http2" ] && echo "    http2 on;")
$([ "$http3" = "on" ] && echo "    listen ${custom_port} quic;")
$([ "$http3" = "on" ] && echo "    http3 on;")
$([ "$http3" = "on" ] && _http3_alt_svc_header_line "$custom_port" "$alt_svc")

    ssl_certificate ${container_cert_path}/fullchain.pem;
    ssl_certificate_key ${container_cert_path}/privkey.pem;
    ssl_protocols $tls_protos;
    ssl_ciphers   $tls_ciphers;
${mtls_directives}
EOF
    if declare -F nginx_directives_render_server_directives >/dev/null 2>&1; then
      if ! nginx_directives_render_server_directives "$config_file" "$dedicated_host" "$custom_port" "$target_domain"; then
        return 1
      fi
    fi
    # Pass target_domain as fallback for path locations
    if ! _emit_path_locations "$config_file" "$dedicated_host" "$custom_port" "$final_upstream" "$ws" "off" "" "$pip_line" "$cip_line" "$proxy_http_version" "$target_domain"; then
      return 1
    fi
    echo "}" >>"$config_file"
  else
    # HTTP server block for dedicated host
    local redirect_flag="${redirect:-off}"
    local redirect_code="$code"
    cat >>"$config_file" <<EOF
server {
    listen ${custom_port};
    server_name ${dedicated_host};
${header_identity_lines}
${realip_lines}
    include ${NGINX_CONTAINER_HTTP_CONF_DIR}/security_ip/${sanitized_host}.inc;
    # security_ip include covers both L7 and L3 policies
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =444;
    }
EOF
    if declare -F nginx_directives_render_server_directives >/dev/null 2>&1; then
      if ! nginx_directives_render_server_directives "$config_file" "$dedicated_host" "$custom_port" "$target_domain"; then
        return 1
      fi
    fi
    # Pass target_domain as fallback for path locations
    if ! _emit_path_locations "$config_file" "$dedicated_host" "$custom_port" "$final_upstream" "$ws" "$redirect_flag" "$redirect_code" "$pip_line" "$cip_line" "$proxy_http_version" "$target_domain"; then
      return 1
    fi
    echo "}" >>"$config_file"
  fi
}
