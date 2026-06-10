# shellcheck shell=bash

function status() {
  _status_run "default"
}

function status_all() {
  _status_run "all"
}

function _status_run() {
  local mode="${1:-default}"
  if [ "${INTERACTIVE:-false}" = true ] && [ -t 0 ] && [ "${STATUS_REFRESH_MODE:-}" != "1" ]; then
    while true; do
      STATUS_REFRESH_MODE=1 _status_render "$mode"
      echo
      local _status_choice=""
      IFS= read -r -n 1 -p "Press R to refresh or Enter to continue... " _status_choice || _status_choice=""
      echo
      if [[ "$_status_choice" =~ ^[Rr]$ ]]; then
        if command -v clear >/dev/null 2>&1; then
          clear
        fi
        continue
      fi
      break
    done
    return 0
  fi
  _status_render "$mode"
}

function _status_render() {
  local mode="${1:-default}"

  echo "=== Nginx Proxy Container ==="
  local managed_nginx_present=false
  local nginx_conflict_present=false
  if nginx_container_exists_any; then
    if nginx_container_is_managed; then
      managed_nginx_present=true
    else
      nginx_conflict_present=true
      warn_if_unmanaged_nginx_container_conflict || true
    fi
  fi
  if [ "$managed_nginx_present" = true ]; then
    local cstat
    cstat="$(container_status "$NGINX_CONTAINER_NAME")"
    echo "$NGINX_CONTAINER_NAME status: ${cstat:-unknown}"
    local running_image
    running_image="$(docker inspect -f '{{.Config.Image}}' "$NGINX_CONTAINER_NAME" 2>/dev/null || true)"
    if [ -n "$running_image" ]; then
      echo "Running image: $running_image"
    fi
    docker ps -a --filter "name=$NGINX_CONTAINER_NAME"
    local desired_bindings current_bindings
    desired_bindings="$(get_all_mapped_port_bindings | xargs)"
    current_bindings="$(container_published_port_bindings "$NGINX_CONTAINER_NAME" | xargs)"
    if [ "$desired_bindings" != "$current_bindings" ]; then
      echo "[Warn] Runtime published bindings (${current_bindings:-none}) differ from configured mapped bindings (${desired_bindings:-none})."
      echo "[Hint] Run ./dockistrate.sh update-nginx-config (without SKIP_DOCKER_CHECKS=true) to reconcile runtime ports."
    fi
  elif [ "$nginx_conflict_present" != "true" ]; then
    echo "Nginx container not found."
  fi
  local describe_container=""
  if [ "$managed_nginx_present" = true ]; then
    describe_container="$NGINX_CONTAINER_NAME"
  fi
  describe_image_with_local_state "$NGINX_IMAGE" "${NGINX_PULL_MODE:-if-missing}" "Configured Nginx" "$describe_container"
  describe_image_with_local_state "$CERTBOT_IMAGE" "${CERTBOT_PULL_MODE:-if-missing}" "Certbot"

  echo
  _status_print_global_settings "$mode"

  echo
  _status_print_host_aliases

  echo
  _status_print_dedicated_hosts

  _status_print_global_headers

  echo
  _status_print_backend_header_overrides

  if [ "$mode" = "all" ]; then
    echo
    _status_print_access_log_fields
  fi

  echo
  _status_print_tls_overrides

  echo
  _status_print_nginx_directives

  echo
  _status_print_backend_summary

  if [ "$mode" = "all" ]; then
    echo
    _status_print_backend_docker_opts
  fi

  echo
  _status_print_port_mappings

  if [ "$mode" = "all" ]; then
    echo
    _status_print_path_options

    echo
    _status_print_certificates
  fi

  _status_print_acl_rules
  _status_print_security_rules
  _status_print_detailed_containers
}

function _status_toggle_display() {
  local raw="${1:-}"
  case "$raw" in
  true | on | yes | 1)
    printf '%s\n' "on"
    ;;
  *)
    printf '%s\n' "off"
    ;;
  esac
}

function _status_capture_state() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx-capture'; then
    printf '%s\n' "active"
  else
    printf '%s\n' "inactive"
  fi
}

function _status_tls_decrypt_state() {
  if capture_tls_decrypt_enabled; then
    printf '%s\n' "on"
  else
    printf '%s\n' "off"
  fi
}

function _status_backup_retention_display() {
  local retention="${1:-}"
  if [ "$retention" = "0" ]; then
    printf '%s\n' "forever"
  else
    printf '%s\n' "$retention days"
  fi
}

function _status_latest_backup_name() {
  local marker_file="${1:-}" latest=""
  if [ -f "$marker_file" ]; then
    latest="$(awk 'NF {line=$0} END {print line}' "$marker_file" 2>/dev/null || true)"
  fi
  if [ -z "$latest" ]; then
    printf '%s\n' "[None]"
    return 0
  fi
  basename "$latest"
}

function _status_print_global_settings() {
  local mode="${1:-default}"
  echo "=== Global Settings ==="
  if [ -f "$BACKEND_HTTP_FILE" ] && [ "$(csv_data_row_count "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "HTTP Version: $HTTP_VERSION (per-backend overrides active)"
  else
    echo "HTTP Version: $HTTP_VERSION"
  fi
  if [ -f "$PORT_TLS_PROTOCOLS_FILE" ] && [ "$(csv_data_row_count "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "TLS Protocols: $TLS_PROTOCOLS (per-port overrides active)"
  else
    echo "TLS Protocols: $TLS_PROTOCOLS"
  fi
  if [ -f "$PORT_TLS_CIPHERS_FILE" ] && [ "$(csv_data_row_count "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "TLS Ciphers: $TLS_CIPHERS (per-port overrides active)"
  else
    echo "TLS Ciphers: $TLS_CIPHERS"
  fi
  echo "Client IP Header: ${CLIENT_IP_HEADER:-off}"
  echo "Proxy IP Header: ${PROXY_IP_HEADER:-off}"
  if [ -n "${NGINX_DOCKER_OPTS:-}" ]; then
    echo "Nginx Docker Opts: ${NGINX_DOCKER_OPTS}"
  else
    echo "Nginx Docker Opts: [None]"
  fi
  if [ -n "$TRUSTED_PROXY_RANGES" ]; then
    echo "Trusted Proxies: $TRUSTED_PROXY_RANGES"
  else
    echo "Trusted Proxies: [None]"
  fi
  echo "ACL Policy: $ACL_POLICY (status $ACL_STATUS)"
  echo "Security Rule Status: $SECURITY_RULE_STATUS"
  if [ "$mode" = "all" ]; then
    echo "Server Tokens: $(show_server_tokens)"
  fi
  echo "Packet Capture: $(_status_capture_state)"
  echo "TLS Decrypt Capture: $(_status_tls_decrypt_state)"
  echo "Auto Backups: $(_status_toggle_display "${ENABLE_AUTO_BACKUPS:-false}")"
  echo "Backup Retention: $(_status_backup_retention_display "${BACKUP_RETENTION:-0}")"
  echo "Backup Compression: $(_status_toggle_display "${ENABLE_BACKUP_COMPRESSION:-false}")"
  echo "Latest Full Backup: $(_status_latest_backup_name "$FULL_BACKUP_FILE")"
  echo "Latest Post-Change Backup: $(_status_latest_backup_name "$LAST_POST_BACKUP_FILE")"
}

function _status_print_host_aliases() {
  echo "=== Host Aliases ==="
  if command -v list_host_aliases >/dev/null 2>&1; then
    (list_host_aliases) || true
  else
    echo "[Info] No host alias helper available."
  fi
}

function _status_print_dedicated_hosts() {
  echo "=== Dedicated Hosts ==="
  if command -v list_dedicated_hosts >/dev/null 2>&1; then
    (list_dedicated_hosts) || true
  else
    echo "[Info] No dedicated hosts helper available."
  fi
}

function _status_print_global_headers() {
  echo "Request Headers:"
  local line="" line_no=0 found_request=false found_response=false
  if [ -f "$CUSTOM_HEADERS_FILE" ] && csv_require_header "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER"; then
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_CUSTOM_HEADERS_COLS" ] || continue
      if [ "${CSV_FIELDS[0]}" = "request" ]; then
        echo "  ${CSV_FIELDS[1]}: ${CSV_FIELDS[2]}"
        found_request=true
      fi
    done <"$CUSTOM_HEADERS_FILE"
  fi
  if [ "$found_request" = false ]; then
    echo "  [None]"
  fi
  echo "Response Headers:"
  line_no=0
  if [ -f "$CUSTOM_HEADERS_FILE" ] && csv_require_header "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER"; then
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_CUSTOM_HEADERS_COLS" ] || continue
      if [ "${CSV_FIELDS[0]}" = "response" ]; then
        echo "  ${CSV_FIELDS[1]}: ${CSV_FIELDS[2]}"
        found_response=true
      fi
    done <"$CUSTOM_HEADERS_FILE"
  fi
  if [ "$found_response" = false ]; then
    echo "  [None]"
  fi
}

function _status_print_backend_header_overrides() {
  echo "=== Backend Header Overrides ==="
  if [ -f "$BACKEND_HEADERS_FILE" ] && [ "$(csv_data_row_count "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" 2>/dev/null || echo 0)" -gt 0 ]; then
    printf "%-20s | %-8s | %-20s | %s\n" "Domain" "Type" "Name" "Value"
    echo "-----------------------------------------------------------------------"
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || continue
      printf "%-20s | %-8s | %-20s | %s\n" "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]}" "${CSV_FIELDS[2]}" "${CSV_FIELDS[3]}"
    done <"$BACKEND_HEADERS_FILE"
  else
    echo "[None]"
  fi
}

function _status_print_access_log_fields() {
  echo "=== Access Log Fields ==="
  if [ ! -f "$ACCESS_LOG_FIELDS_FILE" ]; then
    printf '%s\n' \
      '1:  $realip_remote_addr' \
      '2:  $remote_addr' \
      '3:  $host' \
      '4:  "$request"' \
      '5:  $status' \
      '6:  $body_bytes_sent' \
      '7: [request] "$http_referer"' \
      '8: [request] "$http_user_agent"'
    return 0
  fi
  if ! csv_require_header "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER"; then
    return 1
  fi

  local line="" line_no=0 n=1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid access log field row at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_ACCESS_LOG_FIELDS_COLS" ]; then
      echo "[Error] Invalid access log field column count at line ${line_no}: expected ${STATE_ACCESS_LOG_FIELDS_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    local field tag
    field="${CSV_FIELDS[0]}"
    tag=""
    if [[ "$field" =~ \$sent_http_ ]]; then
      tag="[response]"
    elif [[ "$field" =~ \$http_ ]]; then
      tag="[request]"
    fi
    printf '%d: %s %s\n' "$n" "$tag" "$field"
    n=$((n + 1))
  done <"$ACCESS_LOG_FIELDS_FILE"
}

function _status_print_tls_overrides() {
  echo "=== HTTPS Port TLS Overrides ==="
  if [ -f "$PORT_TLS_PROTOCOLS_FILE" ] || [ -f "$PORT_TLS_CIPHERS_FILE" ]; then
    local ports
    ports=$(
      {
        if [ -f "$PORT_TLS_PROTOCOLS_FILE" ]; then
          awk -F',' 'NR>1 {print $1}' "$PORT_TLS_PROTOCOLS_FILE"
        fi
        if [ -f "$PORT_TLS_CIPHERS_FILE" ]; then
          awk -F',' 'NR>1 {print $1}' "$PORT_TLS_CIPHERS_FILE"
        fi
      } | sort -u
    )
    if [ -n "$ports" ]; then
      printf "%-8s | %-20s | %s\n" "Port" "Protocols" "Ciphers"
      echo "-------------------------------------------------------------"
      local p
      for p in $ports; do
        local proto cipher
        proto=$(get_port_tls_protocols "$p")
        cipher=$(get_port_tls_ciphers "$p")
        [ "$proto" = "$TLS_PROTOCOLS" ] && proto="-"
        [ "$cipher" = "$TLS_CIPHERS" ] && cipher="-"
        printf "%-8s | %-20s | %s\n" "$p" "$proto" "$cipher"
      done
    else
      echo "[None]"
    fi
  else
    echo "[None]"
  fi
}

function _status_print_nginx_directives() {
  echo "=== Nginx Directive Overrides ==="
  if declare -F show_nginx_directive_strict >/dev/null 2>&1; then
    echo "Strict Mode: $(show_nginx_directive_strict)"
  fi
  if declare -F list_nginx_directives >/dev/null 2>&1 && [ -f "$NGINX_DIRECTIVES_FILE" ] && [ "$(csv_data_row_count "$NGINX_DIRECTIVES_FILE" "$STATE_NGINX_DIRECTIVES_HEADER" 2>/dev/null || echo 0)" -gt 0 ]; then
    list_nginx_directives
  else
    echo "[None]"
  fi
}

function _status_print_backend_summary() {
  echo "=== Backend Summary ==="
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local LIST_BACKENDS_INCLUDE_STATE="true"
    list_backends
  else
    echo "[None]"
  fi
}

function _status_print_backend_docker_opts() {
  echo "=== Backend Docker Opts ==="
  if [ ! -f "$BACKEND_DOCKER_OPTS_FILE" ]; then
    echo "[None]"
    return 0
  fi
  if ! csv_require_header "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER"; then
    return 1
  fi
  if [ "$(csv_data_row_count "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER" 2>/dev/null || echo 0)" -le 0 ]; then
    echo "[None]"
    return 0
  fi

  printf "%-26s | %s\n" "Backend" "Docker Opts"
  echo "------------------------------------------------------------------------"
  local line="" line_no=0 found=false
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_DOCKER_OPTS_COLS" ] || continue
    local key opts domain
    key="${CSV_FIELDS[0]}"
    opts="${CSV_FIELDS[1]}"
    case "$key" in
    backend:*)
      domain="${key#backend:}"
      ;;
    *)
      continue
      ;;
    esac
    found=true
    printf "%-26s | %s\n" "$domain" "$opts"
  done <"$BACKEND_DOCKER_OPTS_FILE"
  if [ "$found" = false ]; then
    echo "[None]"
  fi
}

function _status_print_port_mappings() {
  echo "=== Port Mappings (HTTP/HTTPS/TCP) ==="
  if command -v list_port_mappings >/dev/null 2>&1; then
    list_port_mappings || true
  else
    [ -f "$BACKEND_PORTS_FILE" ] && cat "$BACKEND_PORTS_FILE" || echo "[None]"
  fi
}

function _status_print_path_options() {
  echo "=== Path Options ==="
  if declare -F list_path_options >/dev/null 2>&1; then
    list_path_options || true
  else
    echo "[Info] No path option helper available."
  fi
}

function _status_print_certificates() {
  echo "=== Certificates ==="
  if declare -F list_certs >/dev/null 2>&1; then
    list_certs || true
  else
    echo "[Info] No certificate helper available."
  fi
}

function _status_print_acl_rules() {
  echo "=== ACL Rules (Order) ==="
  if [ -f "$SECURITY_IP_RULES_FILE" ] && [ "$(csv_data_row_count "$SECURITY_IP_RULES_FILE" "$STATE_SECURITY_IP_RULES_HEADER" 2>/dev/null || echo 0)" -gt 0 ]; then
    (list_security_ip) || true
  else
    echo "[None]"
  fi
}

function _status_print_security_rules() {
  echo "=== Security Rules (Order) ==="
  if [ -f "$SECURITY_RULES_DB" ] && [ "$(csv_data_row_count "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER" 2>/dev/null || echo 0)" -gt 0 ]; then
    (list_security_rules) || true
  else
    echo "[None]"
  fi
}

function _status_print_detailed_containers() {
  echo "=== Detailed Containers ==="
  echo "[Info] Showing all Docker containers on this host (not only Dockistrate-managed containers)."
  local stats_output sizes_output ps_out
  stats_output="$(get_stats 2>/dev/null || true)"
  sizes_output="$(get_sizes 2>/dev/null || true)"
  ps_out="$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null || true)"

  printf "%-30s | %-20s | %-20s | %-8s | %-10s | %-25s | %-15s | %-15s | %-12s\n" \
    "Container Name" "Image" "State/Uptime" "CPU (%)" "Mem Usage" "Bound Ports" \
    "IP(s)" "Network(s)" "Storage"
  if [ -n "$ps_out" ]; then
    local line
    while IFS= read -r line; do
      local fullName fullImage fullStatus fullPorts
      fullName="$(echo "$line" | cut -d'|' -f1)"
      fullImage="$(echo "$line" | cut -d'|' -f2)"
      fullStatus="$(echo "$line" | cut -d'|' -f3)"
      fullPorts="$(echo "$line" | cut -d'|' -f4)"

      local cState cUptime
      if [[ "$fullStatus" == Up* ]]; then
        cState="Up"
        cUptime="${fullStatus#Up }"
      else
        cState="Exited"
        cUptime="${fullStatus#Exited }"
      fi

      local cpuVal memVal sizeVal
      cpuVal=$(echo "$stats_output" | awk -F'|' -v n="$fullName" '$1==n{print $2}')
      memVal=$(echo "$stats_output" | awk -F'|' -v n="$fullName" '$1==n{print $3}')
      [ -z "$cpuVal" ] && cpuVal="N/A"
      [ -z "$memVal" ] && memVal="N/A"

      sizeVal=$(echo "$sizes_output" | awk -F'|' -v n="$fullName" '$1==n{print $2}')
      [ -z "$sizeVal" ] && sizeVal="N/A"

      local ips nets
      ips=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$fullName" 2>/dev/null | xargs || true)
      nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{ $k }} {{end}}' "$fullName" 2>/dev/null | xargs || true)
      [ -z "$ips" ] && ips="N/A"
      [ -z "$nets" ] && nets="N/A"

      local stateUp="$cState $cUptime"
      printf "%-30s | %-20s | %-20s | %-8s | %-10s | %-25s | %-15s | %-15s | %-12s\n" \
        "$fullName" "$fullImage" "$stateUp" "$cpuVal" "$memVal" "${fullPorts:-N/A}" "$ips" "$nets" "$sizeVal"
    done <<<"$ps_out"
  else
    echo "[Info] No containers found or unable to query Docker."
  fi
}
