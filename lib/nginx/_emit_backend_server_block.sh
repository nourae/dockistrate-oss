# shellcheck shell=bash

# Render a primary backend or an ordinary alias using the primary backend's
# HTTP/HTTPS settings. Served names, ACL includes and request-rule identity vary.
# Header identity keeps the primary default and the existing Host-based alias
# override. Nginx itself derives a missing Host from the selected server_name.
function _emit_backend_server_block() {
  if declare -F domain_config_active >/dev/null 2>&1 && domain_config_active; then
    _domain_config_emit_http _emit_backend_server_block_impl "$@"
  else
    _emit_backend_server_block_impl "$@"
  fi
}

function _emit_backend_server_block_impl() {
  local config_file="$1" domain="$2" server_names="$3" alias_names="$4"
  local acl_domain="$5" custom_port="$6" final_upstream="$7" proto="$8"
  local cert_path="$9" ws="${10}" redirect="${11}" code="${12}"
  local port_http3="${13:-off}" port_alt_svc="${14:-auto}"
  local cip pip realip_lines pip_line cip_line cip_val
  local domain_http_ver header_identity_lines security_identity_lines
  domain_http_ver="$(get_backend_http_version "$domain")" || return 1
  header_identity_lines="$(_backend_header_identity_directives "$domain" "$alias_names")" || return 1
  security_identity_lines="$(_sr_identity_directives "$acl_domain" "$alias_names")" || return 1

  cat >>"$config_file" <<EOF || return 1

# Additional mapping for $domain:$custom_port => $final_upstream
EOF

  cip="$(get_backend_client_ip_header "$domain")" || return 1
  pip="$(get_backend_proxy_ip_header "$domain")" || return 1
  if ! realip_lines="$(_real_ip_directives "$cip")"; then
    return 1
  fi
  local proxy_http_version
  proxy_http_version="$(get_proxy_http_version "$domain")" || return 1
  if [ "$proto" == "https" ]; then
    local container_cert_path
    if ! cert_ref_to_container_dir container_cert_path "$cert_path"; then
      echo "[Error] Failed to resolve certificate directory for domain '${domain}' on port '${custom_port}'." >&2
      return 1
    fi
    if [ -z "$container_cert_path" ]; then
      echo "[Error] Empty certificate directory for domain '${domain}' on port '${custom_port}'." >&2
      return 1
    fi
    local listen_port="${custom_port}"
    local tls_protos tls_ciphers
    tls_protos="$(get_port_tls_protocols "$listen_port")" || return 1
    tls_ciphers="$(get_port_tls_ciphers "$listen_port")" || return 1
    local mtls_directives
    if ! mtls_directives="$(_backend_mtls_directives "$domain")"; then
      echo "[Error] Failed to render mTLS directives for domain '${domain}' on port '${custom_port}'." >&2
      return 1
    fi
    cat >>"$config_file" <<EOF || return 1
server {
    listen ${custom_port} ssl;
    server_name ${server_names};
${security_identity_lines}
${header_identity_lines}
${realip_lines}
    include ${NGINX_CONTAINER_HTTP_CONF_DIR}/security_ip/$(sanitize_domain_name "$acl_domain").inc;
    # security_ip include covers both L7 and L3 policies
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =444;
    }
$([ "$domain_http_ver" = "http2" ] && echo "    http2 on;")
$([ "$port_http3" = "on" ] && echo "    listen ${custom_port} quic;")
$([ "$port_http3" = "on" ] && echo "    http3 on;")
$([ "$port_http3" = "on" ] && _http3_alt_svc_header_line "$custom_port" "$port_alt_svc")

    ssl_certificate ${container_cert_path}/fullchain.pem;
    ssl_certificate_key ${container_cert_path}/privkey.pem;
    ssl_protocols $tls_protos;
    ssl_ciphers   $tls_ciphers;
${mtls_directives}
EOF
    if declare -F nginx_directives_render_server_directives >/dev/null 2>&1; then
      if ! nginx_directives_render_server_directives "$config_file" "$domain" "$custom_port" ""; then
        return 1
      fi
    fi
    pip_line=""
    if [ -n "$pip" ]; then
      if [ -n "$realip_lines" ]; then
        pip_line="        proxy_set_header ${pip} \$realip_remote_addr;"
      else
        pip_line="        proxy_set_header ${pip} \$remote_addr;"
      fi
    fi
    cip_line=""
    if [ -n "$cip" ]; then
      cip_val=$(_client_ip_value_var "$cip") || return 1
      cip_line="        proxy_set_header ${cip} ${cip_val};"
    fi
    if ! _emit_path_locations "$config_file" "$domain" "$custom_port" "$final_upstream" "$ws" "off" "" "$pip_line" "$cip_line" "$proxy_http_version"; then
      return 1
    fi
    echo "}" >>"$config_file" || return 1
  else
    cat >>"$config_file" <<EOF || return 1
server {
    listen ${custom_port};
    server_name ${server_names};
${security_identity_lines}
${header_identity_lines}
${realip_lines}
    include ${NGINX_CONTAINER_HTTP_CONF_DIR}/security_ip/$(sanitize_domain_name "$acl_domain").inc;
    # security_ip include covers both L7 and L3 policies
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =444;
    }
EOF
    if declare -F nginx_directives_render_server_directives >/dev/null 2>&1; then
      if ! nginx_directives_render_server_directives "$config_file" "$domain" "$custom_port" ""; then
        return 1
      fi
    fi
    pip_line=""
    if [ -n "$pip" ]; then
      if [ -n "$realip_lines" ]; then
        pip_line="        proxy_set_header ${pip} \$realip_remote_addr;"
      else
        pip_line="        proxy_set_header ${pip} \$remote_addr;"
      fi
    fi
    cip_line=""
    if [ -n "$cip" ]; then
      cip_val=$(_client_ip_value_var "$cip") || return 1
      cip_line="        proxy_set_header ${cip} ${cip_val};"
    fi
    local redirect_flag redirect_code
    redirect_flag="${redirect:-off}"
    redirect_code="$code"
    if ! _emit_path_locations "$config_file" "$domain" "$custom_port" "$final_upstream" "$ws" "$redirect_flag" "$redirect_code" "$pip_line" "$cip_line" "$proxy_http_version"; then
      return 1
    fi
    echo "}" >>"$config_file" || return 1
  fi

  return 0
}
