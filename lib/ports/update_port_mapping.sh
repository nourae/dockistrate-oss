# shellcheck shell=bash

_UPM_REWRITE_DOMAIN=""
_UPM_REWRITE_MATCH_PORT=""
_UPM_REWRITE_NGINX_PORT=""
_UPM_REWRITE_UPSTREAM_PORT=""
_UPM_REWRITE_PROTOCOL=""
_UPM_REWRITE_CERT_REF=""
_UPM_REWRITE_WS=""
_UPM_REWRITE_REDIRECT_FLAG=""
_UPM_REWRITE_REDIRECT_CODE=""
_UPM_REWRITE_HTTP3=""
_UPM_REWRITE_ALT_SVC=""
_UPM_REWRITE_APPLIED="no"

_UPM_PATH_REWRITE_DOMAIN=""
_UPM_PATH_REWRITE_OLD_PORT=""
_UPM_PATH_REWRITE_NEW_PORT=""

function _update_port_mapping_rewrite_port_row_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
    [ "$STATE_BP_DOMAIN" = "${_UPM_REWRITE_DOMAIN:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_UPM_REWRITE_MATCH_PORT:-}" ]; then
    CSV_FIELDS[6]="${_UPM_REWRITE_NGINX_PORT:-}"
    CSV_FIELDS[7]="${_UPM_REWRITE_UPSTREAM_PORT:-}"
    CSV_FIELDS[8]="${_UPM_REWRITE_PROTOCOL:-}"
    CSV_FIELDS[9]="${_UPM_REWRITE_CERT_REF:-}"
    CSV_FIELDS[10]="${_UPM_REWRITE_WS:-}"
    CSV_FIELDS[11]="${_UPM_REWRITE_REDIRECT_FLAG:-}"
    CSV_FIELDS[12]="${_UPM_REWRITE_REDIRECT_CODE:-}"
    CSV_FIELDS[13]="${_UPM_REWRITE_HTTP3:-off}"
    CSV_FIELDS[14]="${_UPM_REWRITE_ALT_SVC:-auto}"
    _UPM_REWRITE_APPLIED="yes"
  fi
  return 0
}

function _update_port_mapping_rewrite_path_port_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "path" ] &&
    [ "$STATE_BP_DOMAIN" = "${_UPM_PATH_REWRITE_DOMAIN:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_UPM_PATH_REWRITE_OLD_PORT:-}" ]; then
    CSV_FIELDS[6]="${_UPM_PATH_REWRITE_NEW_PORT:-}"
  fi
  return 0
}

function update_port_mapping() {
  local domain="${1:-}" current_port=""
  shift || true

  if [ -z "$domain" ]; then
    echo "[Usage] update-port <domain> [current_port] [--nginx-port port] [--container-port port] [--protocol http|https|tcp|udp] [--cert path|none] [--ws yes|no] [--http3 on|off] [--alt-svc auto|off|custom]"
    exit 1
  fi

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
      exit 1
    fi
    if [ -n "$dedicated_hosts_output" ]; then
      while IFS= read -r dedicated_host_name; do
        [ -n "$dedicated_host_name" ] || continue
        dedicated_hosts_for_backend+=("$dedicated_host_name")
      done <<<"$dedicated_hosts_output"
    fi
  fi

  # Optional second argument selects which existing mapping to update
  if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    current_port="$1"
    shift || true
  fi

  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] No port mappings configured." >&2
    exit 1
  }

  local current="" choice line="" line_no=0
  local matches=()
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      echo "[Error] Invalid backend_ports.csv row at line ${line_no}." >&2
      exit 1
    fi
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
    [ "$STATE_BP_DOMAIN" = "$domain" ] || continue
    if [ -n "$current_port" ] && [ "$STATE_BP_LISTEN_PORT" != "$current_port" ]; then
      continue
    fi
    matches+=("$line")
    if [ -n "$current_port" ]; then
      break
    fi
  done <"$BACKEND_PORTS_FILE"

  if [ -n "$current_port" ]; then
    current="${matches[0]:-}"
  else
    local count=${#matches[@]}
    if [ "$count" -eq 0 ]; then
      echo "[Error] Port mapping for $domain not found." >&2
      exit 1
    elif [ "$count" -gt 1 ] && [ "$INTERACTIVE" = true ]; then
      if declare -F choose_option >/dev/null; then
        local options=() idx
        for line in "${matches[@]}"; do
          state_backend_ports_parse_line "$line" || continue
          options+=("${STATE_BP_LISTEN_PORT} -> ${STATE_BP_UPSTREAM_PORT} proto=${STATE_BP_PROTOCOL} ws=${STATE_BP_WS} cert=${STATE_BP_CERT_REF}")
        done
        if ! choose_option idx "Select port mapping to update:" "${options[@]}"; then
          return 1
        fi
        current="${matches[$idx]}"
      else
        echo "Select port mapping to update:"
        local i=1
        for line in "${matches[@]}"; do
          state_backend_ports_parse_line "$line" || continue
          printf '%d) %s -> %s proto=%s ws=%s cert=%s\n' "$i" "$STATE_BP_LISTEN_PORT" "$STATE_BP_UPSTREAM_PORT" "$STATE_BP_PROTOCOL" "$STATE_BP_WS" "$STATE_BP_CERT_REF"
          i=$((i + 1))
        done
        prompt_input choice "Choice" "1"
        current="${matches[$((choice - 1))]}"
      fi
    else
      current="${matches[0]}"
    fi
  fi

  [ -n "$current" ] || {
    echo "[Error] Port mapping for $domain not found." >&2
    exit 1
  }

  if ! state_backend_ports_parse_line "$current"; then
    echo "[Error] Failed to parse selected port mapping for $domain." >&2
    exit 1
  fi
  local cur_domain="$STATE_BP_DOMAIN" cur_nginx="$STATE_BP_LISTEN_PORT" cur_upstream="$STATE_BP_UPSTREAM_PORT"
  local cur_proto="$STATE_BP_PROTOCOL" cur_cert="$STATE_BP_CERT_REF" cur_ws="$STATE_BP_WS"
  local cur_redirect="$STATE_BP_REDIRECT_FLAG" cur_redirect_code="$STATE_BP_REDIRECT_CODE"
  local cur_http3="${STATE_BP_HTTP3:-off}" cur_alt_svc="${STATE_BP_ALT_SVC:-auto}"
  if [ -n "$cur_cert" ] && [ "$cur_cert" != "none" ]; then
    local normalized_cur_cert
    relativize_cert_dir normalized_cur_cert "$cur_cert"
    cur_cert="$normalized_cur_cert"
  fi
  local nginx_port="" upstream_port="" protocol="" cert_dir="" ws="" http3_opt="" alt_svc_opt=""

  if [ "$INTERACTIVE" = true ] && [ "$#" -eq 0 ]; then
    prompt_input_valid nginx_port "Nginx port" "$cur_nginx" is_valid_port
    prompt_input_valid upstream_port "Container port" "$cur_upstream" is_valid_port
    prompt_input_valid protocol "Protocol" "$cur_proto" is_valid_protocol
    if [ "$protocol" = "https" ]; then
      while true; do
        read_with_editing "Cert path [$cur_cert]: " cert_dir "$cur_cert"
        [ -z "$cert_dir" ] && cert_dir="$cur_cert"
        local abs
        if ! normalize_cert_dir abs "$cert_dir"; then
          continue
        fi
        [ -d "$abs" ] && break
        echo "[Error] Directory not found: $cert_dir" >&2
      done
      prompt_input_valid http3_opt "HTTP3 (on/off)" "$cur_http3" is_valid_http3_flag
      read_with_editing "Alt-Svc [$cur_alt_svc]: " alt_svc_opt "$cur_alt_svc"
      [ -z "$alt_svc_opt" ] && alt_svc_opt="$cur_alt_svc"
      if ! is_valid_alt_svc_mode "$alt_svc_opt"; then
        echo "[Error] Invalid Alt-Svc value." >&2
        exit 1
      fi
    fi
    if [ "$protocol" != "tcp" ] && [ "$protocol" != "udp" ]; then
      prompt_input_valid ws "WebSocket (yes/no)" "$cur_ws" is_yes_no
    fi
  else
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --nginx-port)
        require_option_value "$@" || exit 1
        nginx_port="$2"
        shift 2
        ;;
      --container-port)
        require_option_value "$@" || exit 1
        upstream_port="$2"
        shift 2
        ;;
      --protocol)
        require_option_value "$@" || exit 1
        protocol="$2"
        shift 2
        ;;
      --cert)
        require_option_value "$@" || exit 1
        cert_dir="$2"
        shift 2
        ;;
      --ws)
        require_option_value "$@" || exit 1
        ws="$2"
        shift 2
        ;;
      --http3)
        require_option_value "$@" || exit 1
        http3_opt="$2"
        shift 2
        ;;
      --alt-svc)
        require_option_value "$@" || exit 1
        alt_svc_opt="$2"
        shift 2
        ;;
      *)
        echo "[Usage] update-port <domain> [current_port] [--nginx-port port] [--container-port port] [--protocol http|https|tcp|udp] [--cert path|none] [--ws yes|no] [--http3 on|off] [--alt-svc auto|off|custom]"
        exit 1
        ;;
      esac
    done
  fi

  [ -z "$nginx_port" ] && nginx_port="$cur_nginx"
  [ -z "$upstream_port" ] && upstream_port="$cur_upstream"
  [ -z "$protocol" ] && protocol="$cur_proto"
  [ -z "$cert_dir" ] && cert_dir="$cur_cert"
  [ -z "$ws" ] && ws="$cur_ws"
  [ -z "$http3_opt" ] && http3_opt="$cur_http3"
  [ -z "$alt_svc_opt" ] && alt_svc_opt="$cur_alt_svc"
  if ! validate_http_port_combination "$protocol" "$nginx_port"; then
    exit 1
  fi

  local http3_value="off" alt_svc_value="auto"
  if [ "$protocol" = "https" ]; then
    _parse_http3_flag "$http3_opt" || exit 1
    _parse_alt_svc_mode "$alt_svc_opt" || exit 1
    http3_value="$PORT_HTTP3_FLAG"
    alt_svc_value="$PORT_ALT_SVC_MODE"
  fi

  local udp_skip_domain="" udp_skip_port=""
  if [ "$cur_proto" = "udp" ]; then
    udp_skip_domain="$cur_domain"
    udp_skip_port="$cur_nginx"
  fi

  local redirect_flag="$cur_redirect" redirect_code="$cur_redirect_code"
  if [ "$protocol" != "http" ]; then
    redirect_flag="off"
    redirect_code=""
  fi

  if [ "$nginx_port" != "$cur_nginx" ]; then
    local port_exists="no"
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      if ! state_backend_ports_parse_line "$line"; then
        echo "[Error] Invalid backend_ports.csv row at line ${line_no}." >&2
        exit 1
      fi
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
        [ "$STATE_BP_DOMAIN" = "$domain" ] &&
        [ "$STATE_BP_LISTEN_PORT" = "$nginx_port" ]; then
        port_exists="yes"
        break
      fi
    done <"$BACKEND_PORTS_FILE"
    if [ "$port_exists" = "yes" ]; then
      echo "[Error] Port mapping for $domain on port $nginx_port already exists." >&2
      exit 1
    fi

    local host_transport="tcp"
    [ "$protocol" = "udp" ] && host_transport="udp"
    if ! assert_host_port_available_or_fail "$nginx_port" "$host_transport" "$cur_domain" "$cur_nginx"; then
      exit 1
    fi
  fi

  if [ "$protocol" = "https" ] && [ "$http3_value" = "on" ]; then
    if _udp_mapping_listen_in_use "$nginx_port" "$udp_skip_domain" "$udp_skip_port"; then
      echo "[Error] UDP port ${nginx_port} is already in use by another backend. Choose a different port." >&2
      exit 1
    fi
    if ! assert_host_port_available_or_fail "$nginx_port" "udp" "$udp_skip_domain" "$udp_skip_port"; then
      exit 1
    fi
  fi

  local current_host_transport="tcp" target_host_transport="tcp"
  [ "$cur_proto" = "udp" ] && current_host_transport="udp"
  [ "$protocol" = "udp" ] && target_host_transport="udp"
  if [ "$nginx_port" = "$cur_nginx" ] && [ "$current_host_transport" != "$target_host_transport" ]; then
    if ! assert_host_port_available_or_fail "$nginx_port" "$target_host_transport"; then
      exit 1
    fi
  fi

  begin_transaction "update_port_${domain}_${cur_nginx}_to_${nginx_port}" "$CONFIG_DIR" "$CERTS_DIR"

  if [ "$protocol" = "https" ]; then
    if [ "$cert_dir" = "none" ] || [ -z "$cert_dir" ]; then
      if declare -F add_cert >/dev/null 2>&1; then
        echo "[Info] No certificate provided; generating self-signed cert for ${domain}:${nginx_port}."
        local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
        push_skip_update_nginx_config prev_skip_update
        CERT_AUTOCONFIG_DISABLED=1 add_cert "$domain" "$nginx_port" selfsigned
        pop_skip_update_nginx_config "$prev_skip_update"
        cert_dir="selfsigned/live/${domain}_${nginx_port}"
      else
        echo "[Error] Must provide a valid cert path for HTTPS." >&2
        exit 1
      fi
    fi
    # normalize and verify directory
    local abs
    if ! normalize_cert_dir abs "$cert_dir"; then
      exit 1
    fi
    if [ ! -d "$abs" ]; then
      echo "[Error] Cert directory '$cert_dir' not found." >&2
      exit 1
    fi
    local stored_cert_dir
    relativize_cert_dir stored_cert_dir "$abs"
    cert_dir="$stored_cert_dir"
  elif [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
    cert_dir=""
    ws="no"
    http3_value="off"
    alt_svc_value="auto"
    local skip_domain="" skip_port=""
    if [ "$cur_proto" = "$protocol" ]; then
      skip_domain="$cur_domain"
      skip_port="$cur_nginx"
    fi
    if _stream_listen_in_use "$nginx_port" "$protocol" "$skip_domain" "$skip_port"; then
      local protocol_upper
      protocol_upper="$(printf '%s' "$protocol" | tr '[:lower:]' '[:upper:]')"
      echo "[Error] ${protocol_upper} port ${nginx_port} is already in use by another backend. Choose a different port." >&2
      exit 1
    fi
  elif [ "$protocol" = "http" ]; then
    # ensure HTTP mappings don't retain previous HTTPS certificate references
    cert_dir="none"
    http3_value="off"
    alt_svc_value="auto"
  fi

  local match_port="$cur_nginx"
  local old_directive_scope="$NGINX_DIRECTIVE_SCOPE_PORT"
  local new_directive_scope="$NGINX_DIRECTIVE_SCOPE_PORT"
  if [ "$cur_proto" = "tcp" ] || [ "$cur_proto" = "udp" ]; then
    old_directive_scope="$NGINX_DIRECTIVE_SCOPE_STREAM_PORT"
  fi
  if [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
    new_directive_scope="$NGINX_DIRECTIVE_SCOPE_STREAM_PORT"
  fi

  _UPM_REWRITE_DOMAIN="$domain"
  _UPM_REWRITE_MATCH_PORT="$match_port"
  _UPM_REWRITE_NGINX_PORT="$nginx_port"
  _UPM_REWRITE_UPSTREAM_PORT="$upstream_port"
  _UPM_REWRITE_PROTOCOL="$protocol"
  _UPM_REWRITE_CERT_REF="$cert_dir"
  _UPM_REWRITE_WS="$ws"
  _UPM_REWRITE_REDIRECT_FLAG="$redirect_flag"
  _UPM_REWRITE_REDIRECT_CODE="$redirect_code"
  _UPM_REWRITE_HTTP3="$http3_value"
  _UPM_REWRITE_ALT_SVC="$alt_svc_value"
  _UPM_REWRITE_APPLIED="no"
  if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _update_port_mapping_rewrite_port_row_cb; then
    _rollback_handler
  fi
  if [ "$_UPM_REWRITE_APPLIED" != "yes" ]; then
    echo "[Error] Port mapping for $domain on $match_port not found." >&2
    _rollback_handler
  fi

  if [ "$nginx_port" != "$match_port" ]; then
    _UPM_PATH_REWRITE_DOMAIN="$domain"
    _UPM_PATH_REWRITE_OLD_PORT="$match_port"
    _UPM_PATH_REWRITE_NEW_PORT="$nginx_port"
    if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _update_port_mapping_rewrite_path_port_cb; then
      _rollback_handler
    fi
  fi

  if declare -F nginx_directives_state_remove_matching >/dev/null 2>&1; then
    if [ "$old_directive_scope" = "$new_directive_scope" ]; then
      if [ "$nginx_port" != "$match_port" ]; then
        if ! declare -F nginx_directives_state_retarget_port_scope_rows >/dev/null 2>&1; then
          echo "[Error] Missing nginx directives retarget helper." >&2
          _rollback_handler
        fi
        if ! nginx_directives_state_retarget_port_scope_rows "$old_directive_scope" "$domain" "$match_port" "$new_directive_scope" "$nginx_port"; then
          _rollback_handler
        fi
        if [ "$new_directive_scope" = "$NGINX_DIRECTIVE_SCOPE_PORT" ] && [ "${#dedicated_hosts_for_backend[@]}" -gt 0 ]; then
          local dedicated_host_domain
          for dedicated_host_domain in "${dedicated_hosts_for_backend[@]}"; do
            [ -n "$dedicated_host_domain" ] || continue
            if ! nginx_directives_state_retarget_port_scope_rows "$old_directive_scope" "$dedicated_host_domain" "$match_port" "$new_directive_scope" "$nginx_port"; then
              _rollback_handler
            fi
          done
        fi
      fi
    else
      if ! nginx_directives_state_remove_matching "$old_directive_scope" "$domain" "$match_port" "" "" >/dev/null; then
        _rollback_handler
      fi
      if [ "$old_directive_scope" = "$NGINX_DIRECTIVE_SCOPE_PORT" ] && [ "${#dedicated_hosts_for_backend[@]}" -gt 0 ]; then
        local dedicated_host_domain
        for dedicated_host_domain in "${dedicated_hosts_for_backend[@]}"; do
          [ -n "$dedicated_host_domain" ] || continue
          if ! nginx_directives_state_remove_matching "$old_directive_scope" "$dedicated_host_domain" "$match_port" "" "" >/dev/null; then
            _rollback_handler
          fi
        done
      fi
    fi
  fi

  echo "[Info] Updated port mapping for $domain on $nginx_port."
  create_backup "" "UpdatePort_${domain}_${nginx_port}"
  if ! update_nginx_config; then
    _rollback_handler
  fi
  end_transaction_success
}

# Enable or disable HTTP->HTTPS redirect for an HTTP port mapping
