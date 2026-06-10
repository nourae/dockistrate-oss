# shellcheck shell=bash

function _remove_cert_collect_ports_for_refs() {
  local rel_cert_path="${1:-}" pref_cert_path="${2:-}"
  [ -f "$BACKEND_PORTS_FILE" ] || return 0

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      continue
    fi
    if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
      { [ "$STATE_BP_CERT_REF" = "$rel_cert_path" ] || [ "$STATE_BP_CERT_REF" = "$pref_cert_path" ]; }; then
      printf '%s\n' "$STATE_BP_LISTEN_PORT"
    fi
  done <"$BACKEND_PORTS_FILE"
}

function remove_cert() {
  local domain="${1:-}"
  local port_suffix="${2:-443}"
  local started_txn=false
  [ -z "$domain" ] && {
    echo "[Usage] remove-cert <domain> [port_suffix]"
    exit 1
  }
  require_valid_domain "$domain"
  require_valid_port "$port_suffix"
  domain="$(normalize_domain "$domain")"

  local -a dependent_ports=()
  local ports_seen="|"
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    for t in letsencrypt selfsigned custom; do
      local rel_cert_path="${t}/live/${domain}_${port_suffix}"
      local pref_cert_path="certs/${rel_cert_path}"
      while read -r mapped_port; do
        [ -n "$mapped_port" ] || continue
        case "$ports_seen" in
        *"|${mapped_port}|"*) ;;
        *)
          dependent_ports+=("$mapped_port")
          ports_seen="${ports_seen}${mapped_port}|"
          ;;
        esac
      done < <(_remove_cert_collect_ports_for_refs "$rel_cert_path" "$pref_cert_path")
    done
  fi

  if [ ${#dependent_ports[@]} -gt 0 ]; then
    local ports_str
    ports_str=$(printf '%s\n' "${dependent_ports[@]}" | sort -n | paste -sd',' -)
    echo "[Error] Cannot remove certificate ${domain}_${port_suffix}; port mapping(s) still depend on it (ports: ${ports_str})." >&2
    return 1
  fi

  if ! _config_begin_transaction_if_needed started_txn "remove_cert_${domain}_${port_suffix}" "$CERTS_DIR"; then
    exit 1
  fi

  local removed=false
  local le_rel_cert_path="letsencrypt/live/${domain}_${port_suffix}"
  local le_pref_cert_path="certs/${le_rel_cert_path}"
  local le_shared_source_referenced=false
  if letsencrypt_source_has_remaining_consumers "$domain" "$le_rel_cert_path" "$le_pref_cert_path"; then
    le_shared_source_referenced=true
  fi

  for t in letsencrypt selfsigned custom; do
    local dir="${CERTS_DIR}/${t}/live/${domain}_${port_suffix}"
    if [ -d "$dir" ]; then
      safe_rm_rf "$dir" "${CERTS_DIR}/${t}/live"
      echo "[Info] Removed certificate $dir"
      removed=true
    fi
    if [ "$t" = "letsencrypt" ]; then
      local le_archive_dir="${CERTS_DIR}/${t}/archive"
      local le_port_archive_dir="${le_archive_dir}/${domain}_${port_suffix}"
      if [ -d "$le_port_archive_dir" ]; then
        safe_rm_rf "$le_port_archive_dir" "$le_archive_dir"
        echo "[Info] Removed Let’s Encrypt archive directory $le_port_archive_dir"
        removed=true
      fi

      local le_renewal_dir="${CERTS_DIR}/${t}/renewal"
      local le_port_renewal_conf="${le_renewal_dir}/${domain}_${port_suffix}.conf"
      if [ -f "$le_port_renewal_conf" ]; then
        safe_rm_f "$le_port_renewal_conf" "$le_renewal_dir"
        echo "[Info] Removed Let’s Encrypt renewal config $le_port_renewal_conf"
        removed=true
      fi

      if [ "$le_shared_source_referenced" != true ]; then
        local le_live_dir="${CERTS_DIR}/${t}/live/${domain}"
        if [ -d "$le_live_dir" ]; then
          safe_rm_rf "$le_live_dir" "${CERTS_DIR}/${t}/live"
          echo "[Info] Removed Let’s Encrypt live directory $le_live_dir"
          removed=true
        fi
        local le_shared_archive_dir="${le_archive_dir}/${domain}"
        if [ -d "$le_shared_archive_dir" ]; then
          safe_rm_rf "$le_shared_archive_dir" "$le_archive_dir"
          echo "[Info] Removed Let’s Encrypt archive directory $le_shared_archive_dir"
          removed=true
        fi
        local le_shared_renewal_conf="${le_renewal_dir}/${domain}.conf"
        if [ -f "$le_shared_renewal_conf" ]; then
          safe_rm_f "$le_shared_renewal_conf" "$le_renewal_dir"
          echo "[Info] Removed Let’s Encrypt renewal config $le_shared_renewal_conf"
          removed=true
        fi
      else
        echo "[Info] Preserving shared Let’s Encrypt source assets for ${domain}; other consumers remain."
      fi
    fi
  done
  if [ "$removed" = true ]; then
    create_backup "" "RemoveCert_${domain}_${port_suffix}"
    update_nginx_config
    _config_end_transaction_if_started "$started_txn"
  else
    _config_end_transaction_if_started "$started_txn"
    echo "[Error] Certificate not found for ${domain}_${port_suffix}" >&2
    return 1
  fi
}
