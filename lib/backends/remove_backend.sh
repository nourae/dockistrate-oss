# shellcheck shell=bash
RB_REMOVE_DOMAIN=""

function _remove_backend_restore_skip_update() {
  local prev_skip_update="${1-}"
  if declare -F pop_skip_update_nginx_config >/dev/null 2>&1; then
    pop_skip_update_nginx_config "$prev_skip_update"
    return 0
  fi
  if [ "$prev_skip_update" != "__dockistrate_unset__" ]; then
    SKIP_UPDATE_NGINX_CONFIG="$prev_skip_update"
  else
    unset SKIP_UPDATE_NGINX_CONFIG
  fi
}

function _remove_backend_transaction_step_failed() {
  local label="${1:-cleanup step}"
  echo "[Error] Failed to ${label} while removing backend." >&2
  transaction_return_failure
  return 1
}

function _remove_backend_require_success() {
  local label="${1:-run cleanup step}"
  shift || true
  if "$@"; then
    return 0
  fi
  _remove_backend_transaction_step_failed "$label"
}

function _remove_backend_require_quiet_success() {
  local label="${1:-run cleanup step}" err_file=""
  shift || true

  err_file="$(mktemp "${TMP_DIR:-/tmp}/remove_backend_err.XXXXXX" 2>/dev/null || true)"
  if [ -n "$err_file" ]; then
    if "$@" >/dev/null 2>"$err_file"; then
      rm -f "$err_file"
      return 0
    fi
    _remove_backend_transaction_step_failed "$label"
    if [ -s "$err_file" ]; then
      sed 's/^/[Error]   /' "$err_file" >&2
    fi
    rm -f "$err_file"
    return 1
  fi

  if "$@" >/dev/null 2>/dev/null; then
    return 0
  fi
  _remove_backend_transaction_step_failed "$label"
}

function _remove_backend_drop_security_ip_row() {
  if [ "$(normalize_domain "${CSV_FIELDS[1]-}")" = "$RB_REMOVE_DOMAIN" ]; then
    return 10
  fi
  return 0
}

function _remove_backend_drop_security_rule_row() {
  if [ "$(normalize_domain "${CSV_FIELDS[1]-}")" = "$RB_REMOVE_DOMAIN" ]; then
    return 10
  fi
  return 0
}

function _remove_backend_drop_alias_row() {
  case "${CSV_FIELDS[0]-}" in
  alias | dedicated)
    if [ "$(normalize_domain "${CSV_FIELDS[2]-}")" = "$RB_REMOVE_DOMAIN" ]; then
      return 10
    fi
    ;;
  esac
  return 0
}

function remove_backend() {
  local domain="" assume_yes=false arg=""
  while [ "$#" -gt 0 ]; do
    arg="${1:-}"
    case "$arg" in
    --yes)
      assume_yes=true
      shift
      ;;
    -*)
      echo "[Usage] remove-backend [--yes] <domain>"
      exit 1
      ;;
    *)
      if [ -n "$domain" ]; then
        echo "[Usage] remove-backend [--yes] <domain>"
        exit 1
      fi
      domain="$arg"
      shift
      ;;
    esac
  done
  [ -z "$domain" ] && {
    echo "[Usage] remove-backend [--yes] <domain>"
    exit 1
  }
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi

  local backend_ports_file="${BACKEND_PORTS_FILE:-}"
  local backend_headers_file="${BACKEND_HEADERS_FILE:-}"
  local backend_http_file="${BACKEND_HTTP_FILE:-}"
  local backend_mtls_file="${BACKEND_MTLS_FILE:-}"
  local backend_client_ip_header_file="${BACKEND_CLIENT_IP_HEADER_FILE:-}"
  local backend_proxy_ip_header_file="${BACKEND_PROXY_IP_HEADER_FILE:-}"
  local backend_acl_policy_file="${BACKEND_ACL_POLICY_FILE:-}"
  local backend_acl_status_file="${BACKEND_ACL_STATUS_FILE:-}"
  local backend_security_rule_status_file="${BACKEND_SECURITY_RULE_STATUS_FILE:-}"
  local security_ip_rules_db="${SECURITY_IP_RULES_DB:-}"
  local security_rules_db="${SECURITY_RULES_DB:-}"
  local path_header_dir="${PATH_HEADER_DIR:-}"
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

  local -a domain_path_headers=()
  local -a other_path_headers=()
  if [ -n "$backend_ports_file" ] && [ -f "$backend_ports_file" ]; then
    local entry_line="" entry_line_no=0
    local entry_type="" entry_domain="" entry_header=""
    while IFS= read -r entry_line || [ -n "$entry_line" ]; do
      entry_line_no=$((entry_line_no + 1))
      [ "$entry_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$entry_line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      entry_type="${STATE_BP_RECORD_TYPE:-}"
      entry_domain="${STATE_BP_DOMAIN:-}"
      entry_header="${STATE_BP_HEADER_SET:-}"
      [ "$entry_type" = "path" ] || continue
      [ -n "$entry_header" ] || continue
      if [ "$entry_domain" = "$domain" ]; then
        local seen="false" existing_header
        if [ "${#domain_path_headers[@]}" -gt 0 ]; then
          for existing_header in "${domain_path_headers[@]}"; do
            if [ "$existing_header" = "$entry_header" ]; then
              seen="true"
              break
            fi
          done
        fi
        if [ "$seen" = "false" ]; then
          domain_path_headers+=("$entry_header")
        fi
      else
        local other_seen="false" other_header
        if [ "${#other_path_headers[@]}" -gt 0 ]; then
          for other_header in "${other_path_headers[@]}"; do
            if [ "$other_header" = "$entry_header" ]; then
              other_seen="true"
              break
            fi
          done
        fi
        if [ "$other_seen" = "false" ]; then
          other_path_headers+=("$entry_header")
        fi
      fi
    done <"$backend_ports_file"
  fi

  local -a domain_https_ports=()
  if [ -n "$backend_ports_file" ] && [ -f "$backend_ports_file" ]; then
    local port_line="" port_line_no=0
    local entry_port="" entry_protocol=""
    while IFS= read -r port_line || [ -n "$port_line" ]; do
      port_line_no=$((port_line_no + 1))
      [ "$port_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$port_line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      entry_type="${STATE_BP_RECORD_TYPE:-}"
      entry_domain="${STATE_BP_DOMAIN:-}"
      entry_port="${STATE_BP_LISTEN_PORT:-}"
      entry_protocol="${STATE_BP_PROTOCOL:-}"
      [ "$entry_type" = "port" ] || continue
      [ "$entry_domain" = "$domain" ] || continue
      [ "$entry_protocol" = "https" ] || continue
      [ -n "$entry_port" ] || continue
      local seen="false" existing_port
      if [ "${#domain_https_ports[@]}" -gt 0 ]; then
        for existing_port in "${domain_https_ports[@]}"; do
          if [ "$existing_port" = "$entry_port" ]; then
            seen="true"
            break
          fi
        done
      fi
      if [ "$seen" = "false" ]; then
        domain_https_ports+=("$entry_port")
      fi
    done <"$backend_ports_file"
  fi

  local mtls_dir=""
  if [ -n "$backend_mtls_file" ] && [ -f "$backend_mtls_file" ]; then
    mtls_dir="$(state_csv_get_two_col_value "$backend_mtls_file" "$STATE_BACKEND_MTLS_HEADER" "$domain" "" 2>/dev/null || true)"
  fi
  local normalized_mtls_dir=""
  local mtls_cleanup_required=false
  if [ -n "$mtls_dir" ] && [ -d "$mtls_dir" ]; then
    if ! normalize_mtls_dir normalized_mtls_dir "$mtls_dir"; then
      echo "[Error] Refusing to remove mTLS material outside mTLS certs root (CERTS_DIR/mtls): $mtls_dir" >&2
      return 1
    fi
    mtls_dir="$normalized_mtls_dir"
    mtls_cleanup_required=true
  fi

  local -a backend_headers_to_remove=()
  if [ -n "$backend_headers_file" ] && [ -f "$backend_headers_file" ]; then
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || continue
      local header_domain header_type header_name
      header_domain="${CSV_FIELDS[0]}"
      header_type="${CSV_FIELDS[1]}"
      header_name="${CSV_FIELDS[2]}"
      [ -n "$header_domain" ] || continue
      [ "$header_domain" = "$domain" ] || continue
      [ -n "$header_type" ] || continue
      [ -n "$header_name" ] || continue
      local key="${header_type}|${header_name}" seen="false" existing
      if [ "${#backend_headers_to_remove[@]}" -gt 0 ]; then
        for existing in "${backend_headers_to_remove[@]}"; do
          if [ "$existing" = "$key" ]; then
            seen="true"
            break
          fi
        done
      fi
      if [ "$seen" = "false" ]; then
        backend_headers_to_remove+=("$key")
      fi
    done <"$backend_headers_file"
  fi

  local -a rollback_targets=("$CONFIG_DIR")
  if [ "$mtls_cleanup_required" = true ]; then
    rollback_targets+=("${CERTS_DIR}/mtls")
  fi
  local domain_sane
  domain_sane="$(sanitize_domain_name "$domain")"
  local container_name="backend-${domain_sane}"
  local remove_container_after_config=false
  if container_exists "$container_name"; then
    local noninteractive_policy="auto_yes"
    if [ "$assume_yes" != true ] && [ "${INTERACTIVE:-false}" != true ]; then
      noninteractive_policy="warn_yes"
    fi
    if [ "$assume_yes" != true ] &&
      ! confirm_prompt "Remove container '${container_name}' for domain '${domain}'? (y/n): " "yes_no" "$noninteractive_policy" "--yes"; then
      echo "[Info] Aborting."
      return 0
    fi
    remove_container_after_config=true
  fi
  if ! begin_transaction "remove_backend_${domain}" "${rollback_targets[@]}"; then
    return 1
  fi

  local prev_skip_update="__dockistrate_unset__"
  if declare -F push_skip_update_nginx_config >/dev/null 2>&1; then
    push_skip_update_nginx_config prev_skip_update
  else
    if [ "${SKIP_UPDATE_NGINX_CONFIG+x}" = "x" ]; then
      prev_skip_update="$SKIP_UPDATE_NGINX_CONFIG"
    fi
    SKIP_UPDATE_NGINX_CONFIG=true
  fi

  if [ "${#backend_headers_to_remove[@]}" -gt 0 ]; then
    local header_entry header_type header_name
    for header_entry in "${backend_headers_to_remove[@]}"; do
      header_type="${header_entry%%|*}"
      header_name="${header_entry#*|}"
      if ! _remove_backend_require_quiet_success "remove backend header '${header_type}:${header_name}' for '${domain}'" remove_backend_header "$domain" "$header_type" "$header_name"; then
        _remove_backend_restore_skip_update "$prev_skip_update"
        return 1
      fi
    done
  fi

  if ! _remove_backend_require_quiet_success "remove backend HTTP version for '${domain}'" remove_backend_http_version "$domain"; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi
  if ! _remove_backend_require_quiet_success "disable backend mTLS for '${domain}'" disable_backend_mtls "$domain"; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi
  if ! _remove_backend_require_quiet_success "remove backend client IP header for '${domain}'" remove_backend_client_ip_header "$domain"; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi
  if ! _remove_backend_require_quiet_success "remove backend proxy IP header for '${domain}'" remove_backend_proxy_ip_header "$domain"; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi
  if ! _remove_backend_require_quiet_success "remove backend ACL policy for '${domain}'" remove_backend_acl_policy "$domain"; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi
  if ! _remove_backend_require_quiet_success "remove backend ACL status for '${domain}'" remove_backend_acl_status "$domain"; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi
  if ! _remove_backend_require_quiet_success "remove backend security-rule status for '${domain}'" remove_backend_security_rule_status "$domain"; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi

  if [ "${#domain_https_ports[@]}" -gt 0 ]; then
    local https_port
    for https_port in "${domain_https_ports[@]}"; do
      local shared_port="false"
      if [ -n "$backend_ports_file" ] && [ -f "$backend_ports_file" ]; then
        local shared_line="" shared_line_no=0
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
          [ "$entry_port" = "$https_port" ] || continue
          [ "$entry_domain" = "$domain" ] && continue
          shared_port="true"
          break
        done <"$backend_ports_file"
      fi
      if [ "$shared_port" != "true" ]; then
        if ! _remove_backend_require_quiet_success "remove TLS protocol override for port '${https_port}'" remove_port_tls_protocols "$https_port"; then
          _remove_backend_restore_skip_update "$prev_skip_update"
          return 1
        fi
        if ! _remove_backend_require_quiet_success "remove TLS cipher override for port '${https_port}'" remove_port_tls_ciphers "$https_port"; then
          _remove_backend_restore_skip_update "$prev_skip_update"
          return 1
        fi
      fi
    done
  fi

  local escaped_domain
  escaped_domain="$(escape_sed_literal "$domain")"

  if [ "$remove_container_after_config" != "true" ]; then
    echo "[Info] No container found for '$domain'."
  fi

  if [ -n "$backend_ports_file" ] && [ -f "$backend_ports_file" ]; then
    local had_path="false"
    if grep -Fq "path,${domain}," "$backend_ports_file"; then
      had_path="true"
    fi
    if ! _remove_backend_require_quiet_success "remove backend rows for '${domain}' from ${backend_ports_file}" sed_in_place "/^backend,${escaped_domain},/d" "$backend_ports_file"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
    if ! _remove_backend_require_quiet_success "remove port rows for '${domain}' from ${backend_ports_file}" sed_in_place "/^port,${escaped_domain},/d" "$backend_ports_file"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
    if ! _remove_backend_require_quiet_success "remove path rows for '${domain}' from ${backend_ports_file}" sed_in_place "/^path,${escaped_domain},/d" "$backend_ports_file"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
    echo "[Info] Removed config entries for '$domain' from ${backend_ports_file}."
    if [ "$had_path" = "true" ]; then
      echo "[Info] Removed path overrides for '$domain' from ${backend_ports_file}."
    fi
  fi

  if declare -F nginx_directives_state_remove_for_domain >/dev/null 2>&1; then
    if ! _remove_backend_require_quiet_success "remove Nginx directive state for '${domain}'" nginx_directives_state_remove_for_domain "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
    if [ "${#dedicated_hosts_for_backend[@]}" -gt 0 ]; then
      local dedicated_host_domain
      for dedicated_host_domain in "${dedicated_hosts_for_backend[@]}"; do
        [ -n "$dedicated_host_domain" ] || continue
        if ! _remove_backend_require_quiet_success "remove Nginx directive state for dedicated host '${dedicated_host_domain}'" nginx_directives_state_remove_for_domain "$dedicated_host_domain"; then
          _remove_backend_restore_skip_update "$prev_skip_update"
          return 1
        fi
      done
    fi
  fi

  if [ "${#domain_path_headers[@]}" -gt 0 ] && [ -n "$path_header_dir" ]; then
    local header_set
    for header_set in "${domain_path_headers[@]}"; do
      local shared="false" other_header
      if [ "${#other_path_headers[@]}" -gt 0 ]; then
        for other_header in "${other_path_headers[@]}"; do
          if [ "$other_header" = "$header_set" ]; then
            shared="true"
            break
          fi
        done
      fi
      if [ "$shared" != "true" ]; then
        local include_file="${path_header_dir}/${header_set}.conf"
        if [ -f "$include_file" ]; then
          if ! _remove_backend_require_success "remove path header include '${include_file}'" safe_rm_f "$include_file" "$path_header_dir"; then
            _remove_backend_restore_skip_update "$prev_skip_update"
            return 1
          fi
          echo "[Info] Removed path header include '$include_file'."
        fi
      fi
    done
  fi

  if [ -n "$security_ip_rules_db" ] && [ -f "$security_ip_rules_db" ]; then
    RB_REMOVE_DOMAIN="$domain"
    if ! _remove_backend_require_quiet_success "remove security IP rules for '${domain}'" csv_rewrite_rows "$security_ip_rules_db" "$STATE_SECURITY_IP_RULES_HEADER" "$STATE_SECURITY_IP_RULES_COLS" _remove_backend_drop_security_ip_row; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$security_rules_db" ] && [ -f "$security_rules_db" ]; then
    RB_REMOVE_DOMAIN="$domain"
    if ! _remove_backend_require_quiet_success "remove security rules for '${domain}'" csv_rewrite_rows "$security_rules_db" "$STATE_SECURITY_RULES_HEADER" "$STATE_SECURITY_RULES_COLS" _remove_backend_drop_security_rule_row; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$backend_headers_file" ] && [ -f "$backend_headers_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend header state for '${domain}'" state_csv_delete_by_keys "$backend_headers_file" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 1 "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$backend_mtls_file" ] && [ -f "$backend_mtls_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend mTLS state for '${domain}'" state_csv_delete_two_col_key "$backend_mtls_file" "$STATE_BACKEND_MTLS_HEADER" "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  local removed_aliases=false aliases_file
  aliases_file="$(backend_aliases_file)"
  if [ -f "$aliases_file" ]; then
    RB_REMOVE_DOMAIN="$domain"
    local before_count after_count
    before_count="$(csv_data_row_count "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" 2>/dev/null || echo 0)"
    if ! _remove_backend_require_quiet_success "remove aliases for '${domain}'" csv_rewrite_rows "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" _remove_backend_drop_alias_row; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
    after_count="$(csv_data_row_count "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" 2>/dev/null || echo 0)"
    if [ "$after_count" -lt "$before_count" ]; then
      removed_aliases=true
    fi
  fi
  if [ "${#dedicated_hosts_for_backend[@]}" -gt 0 ]; then
    local dedicated_host_domain
    for dedicated_host_domain in "${dedicated_hosts_for_backend[@]}"; do
      [ -n "$dedicated_host_domain" ] || continue
      if dedicated_host_exists "$dedicated_host_domain"; then
        continue
      fi
      if ! _remove_backend_require_quiet_success "remove inheritance state for dedicated host '${dedicated_host_domain}'" remove_dedicated_host_inheritance "$dedicated_host_domain"; then
        _remove_backend_restore_skip_update "$prev_skip_update"
        return 1
      fi
      if ! _remove_backend_require_quiet_success "remove render state for dedicated host '${dedicated_host_domain}'" remove_domain_keyed_render_state "$dedicated_host_domain"; then
        _remove_backend_restore_skip_update "$prev_skip_update"
        return 1
      fi
    done
  fi

  if [ -n "$backend_http_file" ] && [ -f "$backend_http_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend HTTP version state for '${domain}'" state_csv_delete_two_col_key "$backend_http_file" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$backend_client_ip_header_file" ] && [ -f "$backend_client_ip_header_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend client IP header state for '${domain}'" state_csv_delete_two_col_key "$backend_client_ip_header_file" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$backend_proxy_ip_header_file" ] && [ -f "$backend_proxy_ip_header_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend proxy IP header state for '${domain}'" state_csv_delete_two_col_key "$backend_proxy_ip_header_file" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$backend_acl_policy_file" ] && [ -f "$backend_acl_policy_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend ACL policy state for '${domain}'" state_csv_delete_two_col_key "$backend_acl_policy_file" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$backend_acl_status_file" ] && [ -f "$backend_acl_status_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend ACL status state for '${domain}'" state_csv_delete_two_col_key "$backend_acl_status_file" "$STATE_BACKEND_ACL_STATUSES_HEADER" "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if [ -n "$backend_security_rule_status_file" ] && [ -f "$backend_security_rule_status_file" ]; then
    if ! _remove_backend_require_quiet_success "remove backend security-rule status state for '${domain}'" state_csv_delete_two_col_key "$backend_security_rule_status_file" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" "$domain"; then
      _remove_backend_restore_skip_update "$prev_skip_update"
      return 1
    fi
  fi

  if ! _remove_backend_require_quiet_success "remove backend Docker option state for '${domain}'" set_backend_docker_opts "backend:${domain}" ""; then
    _remove_backend_restore_skip_update "$prev_skip_update"
    return 1
  fi

  _remove_backend_restore_skip_update "$prev_skip_update"

  if ! update_nginx_config; then
    transaction_return_failure
    return 1
  fi
  if [ "$mtls_cleanup_required" = true ] && [ -d "$mtls_dir" ]; then
    if ! _remove_backend_require_success "remove mTLS material for '${domain}'" safe_rm_rf "$mtls_dir" "${CERTS_DIR}/mtls"; then
      return 1
    fi
    echo "[Info] Removed mTLS material for $domain at $mtls_dir."
  fi
  if [ "$remove_container_after_config" = "true" ]; then
    if container_exists "$container_name"; then
      if ! remove_container_and_anonymous_volumes "$container_name"; then
        echo "[Error] Failed to remove backend container '$container_name'." >&2
        _rollback_handler
      fi
      echo "[Info] Removed backend container '$container_name'."
      log_msg "Removed container $container_name."
    else
      echo "[Info] Backend container '$container_name' was already absent before final removal."
      log_msg "Backend container $container_name already absent before final removal."
    fi
  fi
  end_transaction_success

  if [ "$removed_aliases" = true ]; then
    echo "[Info] Removed host aliases associated with '${domain}'."
    log_msg "Removed aliases for backend ${domain}"
  fi
}
