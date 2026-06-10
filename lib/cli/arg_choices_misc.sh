# shellcheck shell=bash

function __arg_choices_yes_no() {
  echo "yes|Yes"
  echo "no|No"
}

function __arg_choices_require_backup() {
  __arg_choices_yes_no
}

function __arg_choices_port_mapping_lines_for_domain() {
  local domain="${1:-}"
  local protocol_filter="${2:-all}"
  [ -f "$BACKEND_PORTS_FILE" ] || return 0
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      continue
    fi
    if [ "$STATE_BP_RECORD_TYPE" = "port" ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
      case "$protocol_filter" in
      stream-only)
        [ "$STATE_BP_PROTOCOL" = "tcp" ] || [ "$STATE_BP_PROTOCOL" = "udp" ] || continue
        ;;
      tcp-only)
        [ "$STATE_BP_PROTOCOL" = "tcp" ] || [ "$STATE_BP_PROTOCOL" = "udp" ] || continue
        ;;
      http-only)
        [ "$STATE_BP_PROTOCOL" = "tcp" ] && continue
        [ "$STATE_BP_PROTOCOL" = "udp" ] && continue
        ;;
      esac
      printf '%s|%s -> %s proto=%s ws=%s cert=%s\n' \
        "$STATE_BP_LISTEN_PORT" "$STATE_BP_LISTEN_PORT" "$STATE_BP_UPSTREAM_PORT" "$STATE_BP_PROTOCOL" "$STATE_BP_WS" "$STATE_BP_CERT_REF"
    fi
  done <"$BACKEND_PORTS_FILE" | sort -n
}

function __arg_choices_cert_folder_ports() {
  local folder="${1:-}"
  [ -f "$BACKEND_PORTS_FILE" ] || return 0
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      continue
    fi
    if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
      [[ "$STATE_BP_CERT_REF" == *"$folder"* ]]; then
      printf '%s\n' "$STATE_BP_LISTEN_PORT"
    fi
  done <"$BACKEND_PORTS_FILE"
}

function __arg_choices_csv_col_values() {
  local file="${1:-}" header="${2:-}" expected_cols="${3:-0}" column_index="${4:-0}"
  [ -f "$file" ] || return 0
  csv_require_header "$file" "$header" || return 0
  local line="" line_no=0 value=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$expected_cols" ] || continue
    value="${CSV_FIELDS[$column_index]-}"
    [ -n "$value" ] || continue
    printf '%s\n' "$value"
  done <"$file"
}

function __arg_choices_backend_domains_all() {
  [ -f "$BACKEND_PORTS_FILE" ] || return 0
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
    [ -n "${STATE_BP_DOMAIN:-}" ] || continue
    printf '%s\n' "$STATE_BP_DOMAIN"
  done <"$BACKEND_PORTS_FILE" | sort -u
}

function __arg_choices_backend_domains_http_https() {
  [ -f "$BACKEND_PORTS_FILE" ] || return 0
  local line="" line_no=0 proto=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
    proto="${STATE_BP_PROTOCOL:-}"
    case "$proto" in
    http | https)
      [ -n "${STATE_BP_DOMAIN:-}" ] || continue
      printf '%s\n' "$STATE_BP_DOMAIN"
      ;;
    esac
  done <"$BACKEND_PORTS_FILE" | sort -u
}

function __arg_choices_dedicated_alias_column() {
  local column_index="${1:-1}"
  local aliases_file
  aliases_file="$(backend_aliases_file)"
  [ -f "$aliases_file" ] || return 0
  csv_require_header "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" || return 0
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || continue
    [ "${CSV_FIELDS[0]-}" = "dedicated" ] || continue
    [ -n "${CSV_FIELDS[$column_index]-}" ] || continue
    printf '%s\n' "${CSV_FIELDS[$column_index]}"
  done <"$aliases_file" | sort -u
}

function __arg_choices_custom_header_names() {
  local type="${1:-}"
  [ -f "$CUSTOM_HEADERS_FILE" ] || return 0
  csv_require_header "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER" || return 0
  local line="" line_no=0 row_type="" row_name=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_CUSTOM_HEADERS_COLS" ] || continue
    row_type="${CSV_FIELDS[0]-}"
    row_name="${CSV_FIELDS[1]-}"
    [ -n "$row_name" ] || continue
    if [ -n "$type" ] && [ "$row_type" != "$type" ]; then
      continue
    fi
    printf '%s\n' "$row_name"
  done <"$CUSTOM_HEADERS_FILE" | sort -u
}

function __arg_choices_backend_header_names() {
  local domain="${1:-}" type="${2:-}"
  [ -f "$BACKEND_HEADERS_FILE" ] || return 0
  csv_require_header "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" || return 0
  local line="" line_no=0 row_domain="" row_type="" row_name=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || continue
    row_domain="${CSV_FIELDS[0]-}"
    row_type="${CSV_FIELDS[1]-}"
    row_name="${CSV_FIELDS[2]-}"
    [ -n "$row_name" ] || continue
    if [ -n "$domain" ] && [ "$row_domain" != "$domain" ]; then
      continue
    fi
    if [ -n "$type" ] && [ "$row_type" != "$type" ]; then
      continue
    fi
    printf '%s\n' "$row_name"
  done <"$BACKEND_HEADERS_FILE" | sort -u
}

function __arg_choices_path_prefixes_for_domain_port() {
  local domain="${1:-}" port="${2:-}"
  [ -f "$BACKEND_PORTS_FILE" ] || return 0
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "${STATE_BP_RECORD_TYPE:-}" = "path" ] &&
      [ "${STATE_BP_DOMAIN:-}" = "$domain" ] &&
      [ "${STATE_BP_LISTEN_PORT:-}" = "$port" ] &&
      [ -n "${STATE_BP_PATH_PREFIX:-}" ]; then
      printf '%s\n' "$STATE_BP_PATH_PREFIX"
    fi
  done <"$BACKEND_PORTS_FILE" | sort -u
}

function __arg_choices_domain() {
  local cmd="$1" aliases_file=""
  case "$cmd" in
  add-backend)
    ;;
  add-dedicated-host)
    __arg_choices_backend_domains_http_https
    ;;
  list-dedicated-hosts)
    __arg_choices_dedicated_alias_column 2
    ;;
  remove-all-path-options)
    echo "__ALL__|All domains"
    __arg_choices_backend_domains_all
    ;;
  enable-backend-mtls)
    __arg_choices_backend_domains_all
    ;;
  add-backend-client-cert | remove-backend-client-cert | list-backend-client-certs | replace-backend-client-cert | export-backend-client-p12 | disable-backend-mtls | replace-backend-ca | remove-backend-ca)
    __arg_choices_csv_col_values "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$STATE_BACKEND_MTLS_COLS" 0 | sort -u
    ;;
  remove-backend-client-ip-header)
    __arg_choices_csv_col_values "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$STATE_BACKEND_CLIENT_IP_HEADERS_COLS" 0 | sort -u
    ;;
  remove-backend-proxy-ip-header)
    __arg_choices_csv_col_values "$BACKEND_PROXY_IP_HEADER_FILE" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" "$STATE_BACKEND_PROXY_IP_HEADERS_COLS" 0 | sort -u
    ;;
  remove-backend-header)
    __arg_choices_csv_col_values "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 0 | sort -u
    ;;
  list-backend-headers)
    {
      __arg_choices_csv_col_values "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 0
      __arg_choices_backend_domains_all
    } | sort -u
    ;;
  remove-backend-http-version)
    __arg_choices_csv_col_values "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$STATE_BACKEND_HTTP_VERSIONS_COLS" 0 | sort -u
    ;;
  remove-backend-acl-policy)
    __arg_choices_csv_col_values "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$STATE_BACKEND_ACL_POLICIES_COLS" 0 | sort -u
    ;;
  remove-backend-acl-status)
    __arg_choices_csv_col_values "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" "$STATE_BACKEND_ACL_STATUSES_COLS" 0 | sort -u
    ;;
  remove-backend-security-rule-status)
    __arg_choices_csv_col_values "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" "$STATE_BACKEND_SECURITY_RULE_STATUSES_COLS" 0 | sort -u
    ;;
  set-nginx-directive | set-nginx-directive-raw | remove-nginx-directive | remove-all-nginx-directives | list-nginx-directives)
    local dscope="${CURRENT_ARGS[0]:-}"
    if [ "$dscope" = "stream-backend" ] || [ "$dscope" = "stream-port" ]; then
      [ -f "$BACKEND_PORTS_FILE" ] && awk -F"," '$1=="backend"{print tolower($2)}' "$BACKEND_PORTS_FILE" | awk 'NF' | sort -u
    else
      {
        [ -f "$BACKEND_PORTS_FILE" ] && awk -F"," '$1=="backend"{print tolower($2)}' "$BACKEND_PORTS_FILE"
        aliases_file="$(backend_aliases_file)"
        [ -f "$aliases_file" ] && awk -F',' '$1=="dedicated"{print tolower($2)}' "$aliases_file"
      } | awk 'NF' | sort -u
    fi
    ;;
  *)
    __arg_choices_backend_domains_all
    ;;
  esac
}

function __arg_choices_hostname() {
  local cmd="$1"
  case "$cmd" in
  remove-dedicated-host | set-dedicated-host-inherit | show-dedicated-host-inherit)
    __arg_choices_dedicated_alias_column 1
    ;;
  esac
}

function __arg_choices_setting() {
  local cmd="$1"
  case "$cmd" in
  set-dedicated-host-inherit)
    local hostname="${CURRENT_ARGS[0]:-}" setting cur_all
    if [ -n "$hostname" ]; then
      for setting in mtls acl security_rules headers paths; do
        echo "${setting}|${setting} (current: $(get_dedicated_host_inheritance "$hostname" "$setting"))"
      done
      cur_all="$(get_dedicated_host_inheritance "$hostname" "mtls")"
      if [ "$cur_all" = "$(get_dedicated_host_inheritance "$hostname" "acl")" ] &&
        [ "$cur_all" = "$(get_dedicated_host_inheritance "$hostname" "security_rules")" ] &&
        [ "$cur_all" = "$(get_dedicated_host_inheritance "$hostname" "headers")" ] &&
        [ "$cur_all" = "$(get_dedicated_host_inheritance "$hostname" "paths")" ]; then
        echo "all|all (current: ${cur_all})"
      else
        echo "all|all (current: mixed)"
      fi
    else
      echo "mtls"
      echo "acl"
      echo "security_rules"
      echo "headers"
      echo "paths"
      echo "all"
    fi
    ;;
  esac
}

function __arg_choices_inherit_mtls() {
  __arg_choices_yes_no
}

function __arg_choices_inherit_acl() {
  __arg_choices_yes_no
}

function __arg_choices_inherit_security_rules() {
  __arg_choices_yes_no
}

function __arg_choices_inherit_headers() {
  __arg_choices_yes_no
}

function __arg_choices_inherit_paths() {
  __arg_choices_yes_no
}

function __arg_choices_value() {
  local cmd="$1"
  case "$cmd" in
  set-dedicated-host-inherit)
    local hostname="${CURRENT_ARGS[0]:-}" setting="${CURRENT_ARGS[1]:-}" current=""
    if [ -n "$hostname" ] && [ -n "$setting" ]; then
      if [ "$setting" = "all" ]; then
        current="$(get_dedicated_host_inheritance "$hostname" "mtls")"
        if [ "$current" != "$(get_dedicated_host_inheritance "$hostname" "acl")" ] ||
          [ "$current" != "$(get_dedicated_host_inheritance "$hostname" "security_rules")" ] ||
          [ "$current" != "$(get_dedicated_host_inheritance "$hostname" "headers")" ] ||
          [ "$current" != "$(get_dedicated_host_inheritance "$hostname" "paths")" ]; then
          current=""
        fi
      else
        current="$(get_dedicated_host_inheritance "$hostname" "$setting")"
      fi
    fi
    local opt label
    for opt in yes no; do
      label="$opt"
      if [ -n "$current" ] && [ "$opt" = "$current" ]; then
        label="${label} (current)"
      fi
      echo "${opt}|${label}"
    done
    ;;
  esac
}

function __arg_choices_header() {
  local cmd="$1"
  case "$cmd" in
  update-header | remove-header)
    __arg_choices_custom_header_names "${CURRENT_ARGS[0]:-}"
    ;;
  update-backend-header | remove-backend-header)
    __arg_choices_backend_header_names "${CURRENT_ARGS[0]:-}" "${CURRENT_ARGS[1]:-}"
    ;;
  esac
}

function __arg_choices_client_name() {
  local cmd="$1"
  case "$cmd" in
  remove-backend-client-cert | replace-backend-client-cert | export-backend-client-p12)
    if [ -n "${CURRENT_ARGS[0]:-}" ]; then
      local mtls_dir normalized_mtls_dir
      mtls_dir="$(get_backend_mtls_dir "${CURRENT_ARGS[0]}")"
      if [ -n "$mtls_dir" ]; then
        normalize_mtls_dir normalized_mtls_dir "$mtls_dir" >/dev/null 2>&1 || return 0
        for crt in "$normalized_mtls_dir"/*.crt; do
          [ -e "$crt" ] || continue
          local base="$(basename "$crt")"
          [ "$base" = "ca.crt" ] && continue
          printf '%s\n' "${base%.crt}"
        done
      fi
    fi
    ;;
  esac
}

function __arg_choices_nginx_port() {
  local cmd="$1"
  case "$cmd" in
  remove-port)
    if [ -n "${CURRENT_ARGS[0]:-}" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      __arg_choices_port_mapping_lines_for_domain "${CURRENT_ARGS[0]}"
    fi
    ;;
  add-path-option | update-path-option | remove-path-option)
    if [ -n "${CURRENT_ARGS[0]:-}" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      __arg_choices_port_mapping_lines_for_domain "${CURRENT_ARGS[0]}" "http-only"
    fi
    ;;
    # legacy tcp port completion removed in unified mode
  esac
}

function __arg_choices_path_prefix() {
  local cmd="$1"
  case "$cmd" in
  update-path-option | remove-path-option)
    if [ -n "${CURRENT_ARGS[0]:-}" ] && [ -n "${CURRENT_ARGS[1]:-}" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      __arg_choices_path_prefixes_for_domain_port "${CURRENT_ARGS[0]}" "${CURRENT_ARGS[1]}"
    fi
    ;;
  set-nginx-directive | set-nginx-directive-raw | remove-nginx-directive | remove-all-nginx-directives | list-nginx-directives)
    if [ "${CURRENT_ARGS[0]:-}" = "path" ] &&
      [ -n "${CURRENT_ARGS[1]:-}" ] &&
      [ -n "${CURRENT_ARGS[2]:-}" ] &&
      [ -f "$BACKEND_PORTS_FILE" ]; then
      __arg_choices_path_prefixes_for_domain_port "${CURRENT_ARGS[1]}" "${CURRENT_ARGS[2]}"
    fi
    ;;
  esac
}

function __arg_choices_port() {
  local cmd="$1"
  case "$cmd" in
  set-port-http3 | list-port-http3)
    list_https_ports
    ;;
  set-port-tls-protocols | set-port-tls-ciphers)
    list_https_ports
    ;;
  set-port-redirect | remove-port-redirect)
    if [ -n "${CURRENT_ARGS[0]:-}" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      __arg_choices_port_mapping_lines_for_domain "${CURRENT_ARGS[0]}"
    fi
    ;;
  remove-port-tls-protocols)
    if [ -f "$PORT_TLS_PROTOCOLS_FILE" ]; then
      local https
      https="$(list_https_ports)"
      __arg_choices_csv_col_values "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" "$STATE_PORT_TLS_PROTOCOLS_COLS" 0 | while read -r p; do
        grep -q "^$p$" <<<"$https" && echo "$p"
      done | sort -u
    fi
    ;;
  remove-port-tls-ciphers)
    if [ -f "$PORT_TLS_CIPHERS_FILE" ]; then
      local https
      https="$(list_https_ports)"
      __arg_choices_csv_col_values "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" "$STATE_PORT_TLS_CIPHERS_COLS" 0 | while read -r p; do
        grep -q "^$p$" <<<"$https" && echo "$p"
      done | sort -u
    fi
    ;;
  set-nginx-directive | set-nginx-directive-raw | remove-nginx-directive | remove-all-nginx-directives | list-nginx-directives)
    local dscope="${CURRENT_ARGS[0]:-}" ddomain="${CURRENT_ARGS[1]:-}"
    if [ -n "$ddomain" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      case "$dscope" in
      port)
        __arg_choices_port_mapping_lines_for_domain "$ddomain" "http-only"
        ;;
      path)
        __arg_choices_port_mapping_lines_for_domain "$ddomain" "http-only"
        ;;
      stream-port)
        __arg_choices_port_mapping_lines_for_domain "$ddomain" "stream-only"
        ;;
      esac
    fi
    ;;
  esac
}

function __arg_choices_directive_scope() {
  local cmd="$1"
  case "$cmd" in
  remove-all-nginx-directives | list-nginx-directives)
    echo "all|All scopes"
    echo "global|Global (http)"
    echo "backend|Backend (server)"
    echo "port|Port (server)"
    echo "path|Path (location)"
    echo "stream-global|Global (stream)"
    echo "stream-backend|Backend (stream)"
    echo "stream-port|Port (stream)"
    ;;
  *)
    echo "global|Global (http)"
    echo "backend|Backend (server)"
    echo "port|Port (server)"
    echo "path|Path (location)"
    echo "stream-global|Global (stream)"
    echo "stream-backend|Backend (stream)"
    echo "stream-port|Port (stream)"
    ;;
  esac
}

function __arg_choices_directive_name() {
  local cmd="$1" scope="${CURRENT_ARGS[0]:-global}"
  if [ "$scope" = "all" ]; then
    scope="global"
  fi
  if [ "$scope" = "backend" ] && [ -z "${CURRENT_ARGS[1]:-}" ]; then
    scope="global"
  fi
  if [ "$scope" = "port" ] && [ -z "${CURRENT_ARGS[2]:-}" ]; then
    scope="global"
  fi
  if [ "$scope" = "path" ] && [ -z "${CURRENT_ARGS[3]:-}" ]; then
    scope="global"
  fi
  if [ "$scope" = "stream-backend" ] && [ -z "${CURRENT_ARGS[1]:-}" ]; then
    scope="stream-global"
  fi
  if [ "$scope" = "stream-port" ] && [ -z "${CURRENT_ARGS[2]:-}" ]; then
    scope="stream-global"
  fi

  if declare -F nginx_directive_catalog_keys_for_scope >/dev/null 2>&1; then
    if [ "$cmd" = "set-nginx-directive" ]; then
      nginx_directive_catalog_keys_for_scope "$scope" | sort -u
      return 0
    fi
    {
      nginx_directive_catalog_keys_for_scope "$scope"
      echo "ssl_protocols"
      echo "ssl_ciphers"
    } | awk 'NF' | sort -u
    return 0
  fi

  if [ "$cmd" = "set-nginx-directive" ]; then
    echo "client_max_body_size"
    echo "client_body_buffer_size"
    echo "client_header_buffer_size"
    echo "large_client_header_buffers"
    echo "proxy_connect_timeout"
    echo "proxy_read_timeout"
    echo "proxy_send_timeout"
    echo "send_timeout"
    echo "proxy_buffering"
    echo "proxy_request_buffering"
    echo "proxy_buffer_size"
    echo "proxy_buffers"
    echo "proxy_busy_buffers_size"
    echo "underscores_in_headers"
    echo "ignore_invalid_headers"
    echo "server_tokens"
    echo "proxy_timeout"
    echo "proxy_protocol"
    echo "proxy_socket_keepalive"
    echo "proxy_download_rate"
    echo "proxy_upload_rate"
    echo "proxy_requests"
    echo "proxy_responses"
    echo "proxy_next_upstream"
    echo "proxy_next_upstream_timeout"
    echo "proxy_next_upstream_tries"
    echo "preread_buffer_size"
    echo "preread_timeout"
    echo "tcp_nodelay"
    echo "ssl_preread"
  else
    {
      echo "client_max_body_size"
      echo "client_body_buffer_size"
      echo "client_header_buffer_size"
      echo "large_client_header_buffers"
      echo "proxy_connect_timeout"
      echo "proxy_read_timeout"
      echo "proxy_send_timeout"
      echo "send_timeout"
      echo "proxy_buffering"
      echo "proxy_request_buffering"
      echo "proxy_buffer_size"
      echo "proxy_buffers"
      echo "proxy_busy_buffers_size"
      echo "underscores_in_headers"
      echo "ignore_invalid_headers"
      echo "server_tokens"
      echo "proxy_timeout"
      echo "proxy_protocol"
      echo "proxy_socket_keepalive"
      echo "proxy_download_rate"
      echo "proxy_upload_rate"
      echo "proxy_requests"
      echo "proxy_responses"
      echo "proxy_next_upstream"
      echo "proxy_next_upstream_timeout"
      echo "proxy_next_upstream_tries"
      echo "preread_buffer_size"
      echo "preread_timeout"
      echo "tcp_nodelay"
      echo "ssl_preread"
      echo "ssl_protocols"
      echo "ssl_ciphers"
    } | sort -u
  fi
}

function __arg_choices_backup() {
  [ -d "$BACKUP_DIR" ] && ls -1 "$BACKUP_DIR" | sort
}

function __arg_choices_true_or_false() {
  echo -e "true\nfalse"
}

function __arg_choices_on_off() {
  echo -e "on\noff"
}

function __arg_choices_expose() {
  echo -e "yes\nno"
}

function __arg_choices_uninstall_scope() {
  echo "backend|Backend state (default)"
  echo "config|Full config + certs"
  echo "all|Config + certs + runtime tmp/capture/acme"
}

function __arg_choices_http3() {
  echo "on|On"
  echo "off|Off"
}

function __arg_choices_alt_svc() {
  echo "auto|Auto"
  echo "off|Off"
  echo "__MANUAL__|Custom (manual value)"
}

function __arg_choices_match() {
  echo "prefix|Prefix"
  echo "exact|Exact"
  echo "regex|Regex"
}

function __arg_choices_priority() {
  echo "100|100 (default)"
  echo "50"
  echo "10"
}

function __arg_choices_target() {
  echo "none|None"
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_rewrite() {
  echo "none|None"
  echo "strip-prefix|Strip prefix"
  echo "replace:/|Replace with /"
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_reason() {
  echo "-|- (unset)"
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_file_mtime_ymd() {
  local path="${1:-}" created=""
  [ -f "$path" ] || {
    echo "Unknown"
    return 0
  }

  if created=$(date -r "$path" +%Y-%m-%d 2>/dev/null); then
    [ -n "$created" ] && {
      echo "$created"
      return 0
    }
  fi
  if created=$(stat -c %y "$path" 2>/dev/null); then
    created="${created%% *}"
    [ -n "$created" ] && {
      echo "$created"
      return 0
    }
  fi
  if created=$(stat -f "%Sm" -t "%Y-%m-%d" "$path" 2>/dev/null); then
    [ -n "$created" ] && {
      echo "$created"
      return 0
    }
  fi

  echo "Unknown"
  return 0
}

function __arg_choices_loc() {
  echo "auto|auto"
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_req_resp() {
  echo -e "request\nresponse"
}

function __arg_choices_cert_path() {
  local cmd="$1"
  if [ -d "$CERTS_DIR" ]; then
    local lines=()
    local t d folder domain_part port_part fullchain expires created cert_type in_use ports ports_str rel_path enddate_line
    for t in letsencrypt selfsigned custom; do
      [ -d "$CERTS_DIR/$t/live" ] || continue
      for d in "$CERTS_DIR/$t/live"/*; do
        [ -d "$d" ] || continue
        folder="$(basename "$d")"
        if [[ "$folder" == *_* ]]; then
          domain_part="${folder%%_*}"
          port_part="${folder##*_}"
        else
          domain_part="$folder"
          port_part="443"
        fi
        fullchain="$d/fullchain.pem"
        [ -f "$fullchain" ] || continue
        if enddate_line="$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null)"; then
          expires="${enddate_line#notAfter=}"
        else
          expires=""
        fi
        created="$(__arg_choices_file_mtime_ymd "$fullchain")"
        case "$t" in
        letsencrypt) cert_type="Let's Encrypt" ;;
        selfsigned) cert_type="Self-Signed" ;;
        custom) cert_type="Custom" ;;
        *) cert_type="Other" ;;
        esac
        in_use="No"
        if [ -f "${NGINX_HTTP_CONF_DIR}/backends.conf" ] && grep -q "$folder" "${NGINX_HTTP_CONF_DIR}/backends.conf"; then
          in_use="Yes"
        fi
        ports=("$port_part")
        if [ -f "$BACKEND_PORTS_FILE" ]; then
          while read -r pm_port; do
            if [[ ! " ${ports[*]} " =~ " $pm_port " ]]; then
              ports+=("$pm_port")
            fi
          done < <(__arg_choices_cert_folder_ports "$folder")
        fi
        ports_str=$(IFS=','; echo "${ports[*]}")
        rel_path="$t/live/$folder"
        lines+=("${rel_path}|${folder} | ${domain_part} | ${cert_type} | ${ports_str} | ${created} | ${expires} | ${in_use}")
      done
    done
    if [ ${#lines[@]} -gt 0 ]; then
      printf '%s\n' "${lines[@]}" | sort
    fi
  fi
  if [ "$cmd" = "add-backend" ]; then
    echo "selfsigned|Generate self-signed certificate"
    echo "letsencrypt|Generate Let's Encrypt certificate"
  else
    echo "none|none"
  fi
}

function __arg_choices_id() {
  local cmd="$1"
  case "$cmd" in
  remove-acl | disable-acl | enable-acl | move-acl-rule | update-acl)
    if [ -f "$SECURITY_IP_RULES_FILE" ]; then
      list_security_ip | sed -E 's/^([0-9]+): */\1|/'
    fi
    ;;
    # legacy L3 ACL commands removed
  remove-security-rule | disable-security-rule | enable-security-rule | move-security-rule | update-security-rule | set-security-rule-mode)
    if [ -f "$SECURITY_RULES_DB" ]; then
      # Only include top-level rule lines (drop indented condition rows). Use awk for BSD/GNU portability.
      list_security_rules | awk -F': *' '$1 ~ /^[0-9]+$/ { print $1 "|" $2 }'
    fi
    ;;
  remove-log-field | update-log-field | move-log-field)
    if [ -f "$ACCESS_LOG_FIELDS_FILE" ]; then
      list_log_fields | sed -E 's/^([0-9]+): */\1|/'
    fi
    ;;
  esac
}
