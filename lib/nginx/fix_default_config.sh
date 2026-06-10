# shellcheck shell=bash

function fix_default_config() {
  local default_cert_file="${NGINX_HTTP_CONF_DIR}/default.crt"
  local default_key_file="${NGINX_HTTP_CONF_DIR}/default.key"
  local default_conf_file="${NGINX_HTTP_CONF_DIR}/default.conf"

  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$NGINX_HTTP_CONF_DIR" "nginx http config directory" || return 1
  fi
  mkdir -p "${NGINX_HTTP_CONF_DIR}"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$NGINX_HTTP_CONF_DIR" "nginx http config directory" || return 1
  fi
  chmod 0750 "${NGINX_HTTP_CONF_DIR}"
  if declare -F validate_tls_settings_for_render >/dev/null 2>&1; then
    validate_tls_settings_for_render || return 1
  fi
  local has_default_tls_cert="false"
  if [ ! -f "$default_cert_file" ] || [ ! -f "$default_key_file" ]; then
    if command -v openssl >/dev/null 2>&1; then
      echo "[Info] Generating self-signed default cert..."
      if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
        runtime_state_paths_guard_if_declared "$default_cert_file" "$default_key_file" || return 1
      fi
      if openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$default_key_file" \
        -out "$default_cert_file" \
        -subj "/CN=default" 2>/dev/null; then
        :
      else
        local openssl_status=$?
        echo "[Warn] Failed to generate self-signed default cert with openssl req (exit status: ${openssl_status}); skipping default HTTPS listener configuration." >&2
        rm -f "$default_cert_file" "$default_key_file"
      fi
    else
      echo "[Warn] OpenSSL not found; skipping default HTTPS listener configuration." >&2
    fi
  fi

  if [ -f "$default_cert_file" ] && [ -f "$default_key_file" ]; then
    has_default_tls_cert="true"
  fi

  if [ -f "$default_cert_file" ]; then
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$default_cert_file" "default certificate file" || return 1
    fi
    chmod 0644 "$default_cert_file"
  fi
  if [ -f "$default_key_file" ]; then
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$default_key_file" "default key file" || return 1
    fi
    chmod 0640 "$default_key_file"
  fi

  local tls_protos tls_ciphers
  tls_protos="$(get_port_tls_protocols 443)"
  tls_ciphers="$(get_port_tls_ciphers 443)"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$default_conf_file" "default nginx config file" || return 1
  fi
  cat >"$default_conf_file" <<EOF
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =444;
    }
    return 444;
}
EOF

  if [ "$has_default_tls_cert" = "true" ]; then
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$default_conf_file" "default nginx config file" || return 1
    fi
    cat >>"$default_conf_file" <<EOF
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate ${NGINX_CONTAINER_HTTP_CONF_DIR}/default.crt;
    ssl_certificate_key ${NGINX_CONTAINER_HTTP_CONF_DIR}/default.key;
    ssl_protocols $tls_protos;
    ssl_ciphers $tls_ciphers;
    return 444;
}
EOF
  fi
  # Add default 444 servers for any additional mapped HTTP/HTTPS ports
  # so that requests without a configured Host on those ports also get 444.
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local http_ports_list="" https_ports_list=""
    local line="" line_no=0 listen_port="" protocol=""
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
      listen_port="${STATE_BP_LISTEN_PORT:-}"
      protocol="${STATE_BP_PROTOCOL:-}"
      [[ "$listen_port" =~ ^[0-9]+$ ]] || continue
      case "$protocol" in
      http) http_ports_list+="${listen_port}"$'\n' ;;
      https) https_ports_list+="${listen_port}"$'\n' ;;
      esac
    done <"$BACKEND_PORTS_FILE"

    # HTTP ports (excluding 80)
    local http_ports
    http_ports="$(printf '%s' "$http_ports_list" | awk 'NF > 0' | sort -u | grep -v '^80$' || true)"
    if [ -n "$http_ports" ]; then
      local p
      for p in $http_ports; do
        if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
          runtime_state_path_guard_if_declared "$default_conf_file" "default nginx config file" || return 1
        fi
        cat >>"$default_conf_file" <<EOF

server {
    listen ${p} default_server;
    server_name _;
    return 444;
}
EOF
      done
    fi
    # HTTPS ports (excluding 443)
    local https_ports
    https_ports="$(printf '%s' "$https_ports_list" | awk 'NF > 0' | sort -u | grep -v '^443$' || true)"
    if [ "$has_default_tls_cert" != "true" ]; then
      if [ -n "$https_ports" ]; then
        echo "[Warn] Default TLS certificate unavailable; skipping additional default HTTPS listener configuration." >&2
      fi
    elif [ -n "$https_ports" ]; then
      local p proto ciph h3_enabled h3_alt_svc
      for p in $https_ports; do
        proto="$(get_port_tls_protocols "$p")"
        ciph="$(get_port_tls_ciphers "$p")"
        h3_enabled="off"
        h3_alt_svc="auto"
        if declare -F get_port_http3_state >/dev/null 2>&1; then
          get_port_http3_state "$p" h3_enabled h3_alt_svc || true
        fi
        if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
          runtime_state_path_guard_if_declared "$default_conf_file" "default nginx config file" || return 1
        fi
        cat >>"$default_conf_file" <<EOF

server {
    listen ${p} ssl default_server;
$([ "$h3_enabled" = "on" ] && echo "    listen ${p} quic;")
$([ "$h3_enabled" = "on" ] && echo "    http3 on;")
$([ "$h3_enabled" = "on" ] && _http3_alt_svc_header_line "$p" "$h3_alt_svc")
    server_name _;
    ssl_certificate ${NGINX_CONTAINER_HTTP_CONF_DIR}/default.crt;
    ssl_certificate_key ${NGINX_CONTAINER_HTTP_CONF_DIR}/default.key;
    ssl_protocols ${proto};
    ssl_ciphers ${ciph};
    return 444;
}
EOF
      done
    fi
  fi
  echo "[Info] Default config re-created."
}
