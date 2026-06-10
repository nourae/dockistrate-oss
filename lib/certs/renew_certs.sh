# shellcheck shell=bash

function renew_certs() {
  local window_days="${CERT_RENEWAL_WINDOW_DAYS:-30}"
  local notify_email="${CERT_RENEWAL_NOTIFY_EMAIL:-}"
  local renewals_performed=false
  local seen="|"
  local renewal_sources_seen="|"
  local started_txn=false

  echo "[Info] Scanning configured HTTPS certificates (renewal window: ${window_days} days)..."
  log_msg "Starting certificate renewal scan (window=${window_days}d)"

  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Warn] No port mappings found; nothing to renew."
    log_msg "Skipping renewal scan; ${BACKEND_PORTS_FILE} missing"
    return 0
  fi

  if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    return 1
  fi

  local line="" line_no=0 cert_dir=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    if ! state_backend_ports_parse_line "$line"; then
      _notify_cert_warning "Skipping invalid backend_ports row at line ${line_no}" "$notify_email"
      continue
    fi

    [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
    [ "$STATE_BP_PROTOCOL" = "https" ] || continue
    cert_dir="$STATE_BP_CERT_REF"
    [ -n "$cert_dir" ] || continue

    if [[ "$seen" == *"|$cert_dir|"* ]]; then
      continue
    fi
    seen+="${cert_dir}|"

    local abs_cert_dir=""
    if ! normalize_cert_dir abs_cert_dir "$cert_dir"; then
      _notify_cert_warning "Skipping invalid certificate path '${cert_dir}'" "$notify_email"
      continue
    fi

    local fullchain="${abs_cert_dir}/fullchain.pem"
    local privkey="${abs_cert_dir}/privkey.pem"
    local enddate=""

    if [ ! -f "$fullchain" ]; then
      _notify_cert_warning "Certificate missing for ${cert_dir} (expected ${fullchain})" "$notify_email"
      continue
    fi

    enddate=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2)
    echo "[Info] ${cert_dir} expires on ${enddate:-unknown}."

    if ! _cert_expiring_soon "$fullchain" "$window_days"; then
      log_msg "Certificate ${cert_dir} valid beyond ${window_days} days"
      continue
    fi

    if [[ "$cert_dir" != letsencrypt/* && "$cert_dir" != certs/letsencrypt/* ]]; then
      _notify_cert_warning "Certificate at ${cert_dir} expires soon (on ${enddate:-unknown}) and is not managed by Let's Encrypt. Update it manually." "$notify_email"
      continue
    fi

    local le_domain=""
    if ! letsencrypt_source_domain_from_cert_ref le_domain "$cert_dir"; then
      _notify_cert_warning "Skipping invalid Let's Encrypt certificate path '${cert_dir}'" "$notify_email"
      continue
    fi
    [ -n "$le_domain" ] || continue

    if [[ "$renewal_sources_seen" != *"|$le_domain|"* ]]; then
      if [ "$started_txn" != "true" ]; then
        if ! _config_begin_transaction_if_needed started_txn "renew_certs" "$CERTS_DIR" "$ACME_WEBROOT_DIR"; then
          return 1
        fi
      fi

      if ! _renew_letsencrypt_cert "$le_domain"; then
        _notify_cert_warning "Renewal failed for ${le_domain}; rolling back certificate updates." "$notify_email"
        _rollback_handler
      fi
      renewal_sources_seen+="${le_domain}|"
    fi

    local source_dir="${CERTS_DIR}/letsencrypt/live/${le_domain}"
    if [ -d "$source_dir" ]; then
      if [ "$source_dir" != "$abs_cert_dir" ]; then
        if ! copy_file_atomic "$source_dir/fullchain.pem" "$fullchain" 640 ||
          ! copy_file_atomic "$source_dir/privkey.pem" "$privkey" 600; then
          _notify_cert_warning "Renewal for ${le_domain} is being rolled back because live cert copy refresh failed for ${cert_dir}" "$notify_email"
          _rollback_handler
        fi
      fi
      echo "[Info] Updated certificate files at ${cert_dir}"
      log_msg "Updated live copy for ${cert_dir} after renewal"
      renewals_performed=true
    else
      _notify_cert_warning "Renewal for ${le_domain} is being rolled back because ${source_dir} was not found" "$notify_email"
      _rollback_handler
    fi
  done <"$BACKEND_PORTS_FILE"

  if [ "$renewals_performed" = true ]; then
    update_nginx_config
    _config_end_transaction_if_started "$started_txn"
    echo "[Info] Renewal scan finished; Nginx configuration refreshed."
    log_msg "Certificate renewal scan completed with updates"
  else
    _config_end_transaction_if_started "$started_txn"
    echo "[Info] Renewal scan finished; no certificates required renewal."
    log_msg "Certificate renewal scan completed without changes"
  fi
}
