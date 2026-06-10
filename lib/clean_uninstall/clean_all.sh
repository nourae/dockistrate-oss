# shellcheck shell=bash

CLEAN_REMOVE_DOMAIN=""

function _clean_all_drop_security_ip_row() {
  if [ "$(normalize_domain "${CSV_FIELDS[1]-}")" = "$CLEAN_REMOVE_DOMAIN" ]; then
    return 10
  fi
  return 0
}

function _clean_all_drop_security_rule_row() {
  if [ "$(normalize_domain "${CSV_FIELDS[1]-}")" = "$CLEAN_REMOVE_DOMAIN" ]; then
    return 10
  fi
  return 0
}

function _clean_all_drop_alias_row() {
  case "${CSV_FIELDS[0]-}" in
  alias | dedicated)
    if [ "$(normalize_domain "${CSV_FIELDS[2]-}")" = "$CLEAN_REMOVE_DOMAIN" ]; then
      return 10
    fi
    ;;
  esac
  return 0
}

function _clean_all_require_success() {
  local description="${1:-}"
  shift || true

  if "$@"; then
    return 0
  fi

  if [ -n "$description" ]; then
    echo "[Error] Failed to ${description}." >&2
  fi
  return 1
}

function _clean_all_run_quietly() {
  "$@" >/dev/null
}

function _clean_all_require_quiet_success() {
  local description="${1:-}"
  shift || true

  _clean_all_require_success "$description" _clean_all_run_quietly "$@"
}

function clean_all() {
  local domain="${1:-}"
  local -a dedicated_hosts_for_backend=()
  local dedicated_hosts_output="" dedicated_host_name=""
  [ -z "$domain" ] && {
    echo "[Usage] clean-all <domain>"
    exit 1
  }
  domain="$(normalize_domain "$domain")"

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

  local started_txn=false
  if ! transaction_is_active; then
    if ! begin_transaction "clean_all_${domain}" "$CONFIG_DIR" "$CERTS_DIR"; then
      return 1
    fi
    started_txn=true
  fi

  local escaped_domain
  escaped_domain="$(escape_sed_literal "$domain")"

  local -a domain_path_headers=()
  local -a other_path_headers=()
  local -a domain_https_ports=()
  local -a domain_cert_refs=()
  local -a domain_le_source_domains=()
  if [ -f "$BACKEND_PORTS_FILE" ]; then
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
    done <"$BACKEND_PORTS_FILE"
  fi

  if [ -f "$BACKEND_PORTS_FILE" ]; then
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
      local entry_cert_ref="${STATE_BP_CERT_REF:-}"
      [ "$entry_type" = "port" ] || continue
      [ "$entry_domain" = "$domain" ] || continue
      if [ -n "$entry_cert_ref" ] && [ "$entry_cert_ref" != "none" ]; then
        local canonical_cert_ref=""
        if canonicalize_cert_ref_rel canonical_cert_ref "$entry_cert_ref"; then
          entry_cert_ref="$canonical_cert_ref"
        fi
        local cert_seen="false" existing_cert_ref
        if [ "${#domain_cert_refs[@]}" -gt 0 ]; then
          for existing_cert_ref in "${domain_cert_refs[@]}"; do
            if [ "$existing_cert_ref" = "$entry_cert_ref" ]; then
              cert_seen="true"
              break
            fi
          done
        fi
        if [ "$cert_seen" = "false" ]; then
          domain_cert_refs+=("$entry_cert_ref")
        fi
      fi
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
    done <"$BACKEND_PORTS_FILE"
  fi

  if [ "${#domain_cert_refs[@]}" -gt 0 ]; then
    local domain_cert_ref="" le_source_domain=""
    for domain_cert_ref in "${domain_cert_refs[@]}"; do
      if ! letsencrypt_source_domain_from_cert_ref le_source_domain "$domain_cert_ref"; then
        continue
      fi
      [ -n "$le_source_domain" ] || continue

      local le_source_seen="false" existing_le_source_domain=""
      if [ "${#domain_le_source_domains[@]}" -gt 0 ]; then
        for existing_le_source_domain in "${domain_le_source_domains[@]}"; do
          if [ "$existing_le_source_domain" = "$le_source_domain" ]; then
            le_source_seen="true"
            break
          fi
        done
      fi
      if [ "$le_source_seen" = "false" ]; then
        domain_le_source_domains+=("$le_source_domain")
      fi
    done
  fi

  local shared_le_source_present="false"
  if [ -d "${CERTS_DIR}/letsencrypt/live/${domain}" ] ||     [ -d "${CERTS_DIR}/letsencrypt/archive/${domain}" ] ||     [ -f "${CERTS_DIR}/letsencrypt/renewal/${domain}.conf" ]; then
    shared_le_source_present="true"
  fi

  if [ "$shared_le_source_present" = "true" ]; then
    local le_source_seen="false" existing_le_source_domain=""
    if [ "${#domain_le_source_domains[@]}" -gt 0 ]; then
      for existing_le_source_domain in "${domain_le_source_domains[@]}"; do
        if [ "$existing_le_source_domain" = "$domain" ]; then
          le_source_seen="true"
          break
        fi
      done
    fi
    if [ "$le_source_seen" = "false" ]; then
      domain_le_source_domains+=("$domain")
    fi
  fi

  local mtls_dir=""
  if [ -f "$BACKEND_MTLS_FILE" ]; then
    mtls_dir="$(state_csv_get_two_col_value "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$domain" "" 2>/dev/null || true)"
  fi

  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local had_path="false"
    if grep -Fq "path,${domain}," "$BACKEND_PORTS_FILE"; then
      had_path="true"
    fi
    sed_in_place "/^backend,${escaped_domain},/d" "$BACKEND_PORTS_FILE"
    sed_in_place "/^port,${escaped_domain},/d" "$BACKEND_PORTS_FILE"
    sed_in_place "/^path,${escaped_domain},/d" "$BACKEND_PORTS_FILE"
    echo "[Info] Removed $domain from $BACKEND_PORTS_FILE."
    if [ "$had_path" = "true" ]; then
      echo "[Info] Removed path overrides for '$domain' from $BACKEND_PORTS_FILE."
    fi
  fi

  if declare -F nginx_directives_state_remove_for_domain >/dev/null 2>&1; then
    _clean_all_require_quiet_success \
      "remove persisted nginx directives for '${domain}'" \
      nginx_directives_state_remove_for_domain "$domain" || return 1
    if [ "${#dedicated_hosts_for_backend[@]}" -gt 0 ]; then
      local dedicated_host_domain
      for dedicated_host_domain in "${dedicated_hosts_for_backend[@]}"; do
        [ -n "$dedicated_host_domain" ] || continue
        _clean_all_require_quiet_success \
          "remove persisted nginx directives for dedicated host '${dedicated_host_domain}'" \
          nginx_directives_state_remove_for_domain "$dedicated_host_domain" || return 1
      done
    fi
  fi

  if [ "${#domain_path_headers[@]}" -gt 0 ]; then
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
        local include_file="${PATH_HEADER_DIR}/${header_set}.conf"
        if [ -f "$include_file" ]; then
          safe_rm_f "$include_file" "$PATH_HEADER_DIR"
          echo "[Info] Removed path header include '$include_file'."
        fi
      fi
    done
  fi

  local -a backend_headers_to_remove=()
  if [ -f "$BACKEND_HEADERS_FILE" ]; then
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
    done <"$BACKEND_HEADERS_FILE"
  fi

  local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
  SKIP_UPDATE_NGINX_CONFIG=true

  if [ "${#backend_headers_to_remove[@]}" -gt 0 ]; then
    local header_entry header_type header_name
    for header_entry in "${backend_headers_to_remove[@]}"; do
      header_type="${header_entry%%|*}"
      header_name="${header_entry#*|}"
      _clean_all_require_quiet_success \
        "remove ${header_type} backend header '${header_name}' for '${domain}'" \
        remove_backend_header "$domain" "$header_type" "$header_name" || return 1
    done
  fi

  _clean_all_require_quiet_success "remove backend HTTP version override for '${domain}'" remove_backend_http_version "$domain" || return 1
  _clean_all_require_quiet_success "disable backend mTLS for '${domain}'" disable_backend_mtls "$domain" || return 1
  _clean_all_require_quiet_success "remove backend client IP header override for '${domain}'" remove_backend_client_ip_header "$domain" || return 1
  _clean_all_require_quiet_success "remove backend proxy IP header override for '${domain}'" remove_backend_proxy_ip_header "$domain" || return 1
  _clean_all_require_quiet_success "remove backend ACL policy override for '${domain}'" remove_backend_acl_policy "$domain" || return 1
  _clean_all_require_quiet_success "remove backend ACL status override for '${domain}'" remove_backend_acl_status "$domain" || return 1
  _clean_all_require_quiet_success "remove backend security rule status override for '${domain}'" remove_backend_security_rule_status "$domain" || return 1

  if [ "${#domain_https_ports[@]}" -gt 0 ]; then
    local https_port
    for https_port in "${domain_https_ports[@]}"; do
      local shared_port="false"
      if [ -f "$BACKEND_PORTS_FILE" ]; then
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
        done <"$BACKEND_PORTS_FILE"
      fi
      if [ "$shared_port" != "true" ]; then
        _clean_all_require_quiet_success "remove TLS protocol override for port '${https_port}'" remove_port_tls_protocols "$https_port" || return 1
        _clean_all_require_quiet_success "remove TLS cipher override for port '${https_port}'" remove_port_tls_ciphers "$https_port" || return 1
      fi
    done
  fi

  if [ -f "$SECURITY_IP_RULES_DB" ]; then
    CLEAN_REMOVE_DOMAIN="$domain"
    _clean_all_require_success \
      "remove persisted security IP rules for '${domain}'" \
      csv_rewrite_rows "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER" "$STATE_SECURITY_IP_RULES_COLS" _clean_all_drop_security_ip_row || return 1
  fi

  if [ -f "$SECURITY_RULES_DB" ]; then
    CLEAN_REMOVE_DOMAIN="$domain"
    _clean_all_require_success \
      "remove persisted security rules for '${domain}'" \
      csv_rewrite_rows "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER" "$STATE_SECURITY_RULES_COLS" _clean_all_drop_security_rule_row || return 1
  fi

  local aliases_file
  aliases_file="$(backend_aliases_file)"
  if [ -f "$aliases_file" ]; then
    CLEAN_REMOVE_DOMAIN="$domain"
    _clean_all_require_success \
      "remove persisted aliases for '${domain}'" \
      csv_rewrite_rows "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" _clean_all_drop_alias_row || return 1
  fi
  if [ "${#dedicated_hosts_for_backend[@]}" -gt 0 ]; then
    local dedicated_host_domain
    for dedicated_host_domain in "${dedicated_hosts_for_backend[@]}"; do
      [ -n "$dedicated_host_domain" ] || continue
      if dedicated_host_exists "$dedicated_host_domain"; then
        continue
      fi
      _clean_all_require_quiet_success \
        "remove dedicated host inheritance for '${dedicated_host_domain}'" \
        remove_dedicated_host_inheritance "$dedicated_host_domain" || return 1
      _clean_all_require_quiet_success \
        "remove dedicated host keyed overrides for '${dedicated_host_domain}'" \
        remove_domain_keyed_render_state "$dedicated_host_domain" || return 1
    done
  fi

  if [ -f "$BACKEND_HEADERS_FILE" ]; then
    state_csv_delete_by_keys "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 1 "$domain"
  fi

  if [ -f "$BACKEND_MTLS_FILE" ]; then
    state_csv_delete_two_col_key "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$domain"
  fi

  if [ -f "$BACKEND_HTTP_FILE" ]; then
    state_csv_delete_two_col_key "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$domain"
  fi

  if [ -f "$BACKEND_CLIENT_IP_HEADER_FILE" ]; then
    state_csv_delete_two_col_key "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$domain"
  fi

  if [ -f "$BACKEND_PROXY_IP_HEADER_FILE" ]; then
    state_csv_delete_two_col_key "$BACKEND_PROXY_IP_HEADER_FILE" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" "$domain"
  fi

  if [ -f "$BACKEND_ACL_POLICY_FILE" ]; then
    state_csv_delete_two_col_key "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$domain"
  fi

  if [ -f "$BACKEND_ACL_STATUS_FILE" ]; then
    state_csv_delete_two_col_key "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" "$domain"
  fi

  if [ -f "$BACKEND_SECURITY_RULE_STATUS_FILE" ]; then
    state_csv_delete_two_col_key "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" "$domain"
  fi

  if [ "$prev_skip_update" = "true" ]; then
    SKIP_UPDATE_NGINX_CONFIG="true"
  else
    unset SKIP_UPDATE_NGINX_CONFIG
  fi

  if [ -n "$mtls_dir" ] && [ -d "$mtls_dir" ]; then
    local normalized_mtls_dir=""
    if ! normalize_mtls_dir normalized_mtls_dir "$mtls_dir"; then
      echo "[Error] Refusing to remove mTLS material outside certs root: $mtls_dir" >&2
      return 1
    fi
    mtls_dir="$normalized_mtls_dir"
    safe_rm_rf "$mtls_dir" "${CERTS_DIR}/mtls"
    echo "[Info] Removed mTLS material for $domain at $mtls_dir."
  fi

  set_backend_docker_opts "backend:${domain}" ""

  if [ -d "$CERTS_DIR" ]; then
    local providers=(letsencrypt selfsigned custom)
    local had_nullglob=0
    if shopt -q nullglob; then
      had_nullglob=1
    else
      shopt -s nullglob
    fi
    for provider in "${providers[@]}"; do
      local provider_live_dir="${CERTS_DIR}/${provider}/live"
      if [ -d "$provider_live_dir" ]; then
        if [ "$provider" = "letsencrypt" ]; then
          for cert_dir in "${provider_live_dir}/${domain}_"*; do
            [ -d "$cert_dir" ] || continue
            safe_rm_rf "$cert_dir" "$provider_live_dir"
            echo "[Info] Removed cert directory (${provider}): $cert_dir"
          done
        else
          for cert_dir in "${provider_live_dir}/${domain}" "${provider_live_dir}/${domain}_"*; do
            [ -d "$cert_dir" ] || continue
            safe_rm_rf "$cert_dir" "$provider_live_dir"
            echo "[Info] Removed cert directory (${provider}): $cert_dir"
          done
        fi
      fi
      if [ "$provider" = "letsencrypt" ]; then
        local le_archive_dir="${CERTS_DIR}/${provider}/archive"
        if [ -d "$le_archive_dir" ]; then
          for archive_dir in "${le_archive_dir}/${domain}_"*; do
            [ -d "$archive_dir" ] || continue
            safe_rm_rf "$archive_dir" "$le_archive_dir"
            echo "[Info] Removed Let’s Encrypt archive directory: $archive_dir"
          done
        fi
        local le_renewal_dir="${CERTS_DIR}/${provider}/renewal"
        if [ -d "$le_renewal_dir" ]; then
          for renewal_conf in "${le_renewal_dir}/${domain}_"*.conf; do
            [ -f "$renewal_conf" ] || continue
            safe_rm_f "$renewal_conf" "$le_renewal_dir"
            echo "[Info] Removed Let’s Encrypt renewal config: $renewal_conf"
          done
        fi

        if [ "${#domain_le_source_domains[@]}" -gt 0 ]; then
          local source_domain=""
          for source_domain in "${domain_le_source_domains[@]}"; do
            [ -n "$source_domain" ] || continue
            if letsencrypt_source_has_remaining_consumers "$source_domain"; then
              echo "[Info] Preserving shared Let’s Encrypt source assets for ${source_domain}; other consumers remain."
              continue
            fi

            local le_live_dir="${provider_live_dir}/${source_domain}"
            if [ -d "$le_live_dir" ]; then
              safe_rm_rf "$le_live_dir" "$provider_live_dir"
              echo "[Info] Removed cert directory (${provider}): $le_live_dir"
            fi

            if [ -d "$le_archive_dir" ]; then
              local le_shared_archive_dir="${le_archive_dir}/${source_domain}"
              if [ -d "$le_shared_archive_dir" ]; then
                safe_rm_rf "$le_shared_archive_dir" "$le_archive_dir"
                echo "[Info] Removed Let’s Encrypt archive directory: $le_shared_archive_dir"
              fi
            fi

            if [ -d "$le_renewal_dir" ]; then
              local le_shared_renewal_conf="${le_renewal_dir}/${source_domain}.conf"
              if [ -f "$le_shared_renewal_conf" ]; then
                safe_rm_f "$le_shared_renewal_conf" "$le_renewal_dir"
                echo "[Info] Removed Let’s Encrypt renewal config: $le_shared_renewal_conf"
              fi
            fi
          done
        fi
      fi
    done
    [ "$had_nullglob" -eq 1 ] || shopt -u nullglob
  fi

  create_backup "" "CleanAll_${domain}"
  update_nginx_config

  local cname="backend-$(sanitize_domain_name "$domain")"
  if [ "$started_txn" = true ]; then
    if ! _cleanup_runtime_stage_container_delete "$cname"; then
      echo "[Error] Failed to stage deletion for backend container '$cname'." >&2
      return 1
    fi
  elif container_exists "$cname"; then
    if ! remove_container_and_anonymous_volumes "$cname"; then
      echo "[Error] Failed to remove backend container '$cname'." >&2
      return 1
    fi
    echo "[Info] Removed container '$cname'."
  fi

  if [ "$started_txn" = true ]; then
    end_transaction_success
    if ! _cleanup_runtime_finalize_staged_deletes; then
      return 1
    fi
  fi
}
