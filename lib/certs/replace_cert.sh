# shellcheck shell=bash

# Replace an existing certificate with a newly generated one
function replace_cert() {
  local domain="${1:-}"
  local port_suffix="${2:-443}"
  local cert_choice="${3:-}"
  local upload_fc="${4:-}"
  local upload_pk="${5:-}"
  local started_txn=false

  if [ -z "$domain" ]; then
    echo "[Usage] replace-cert <domain> [port_suffix] [selfsigned|letsencrypt|upload] [fullchain] [privkey]"
    exit 1
  fi

  require_valid_domain "$domain"
  require_valid_port "$port_suffix"
  domain="$(normalize_domain "$domain")"

  local cert_type
  case "$cert_choice" in
  [Ss] | selfsigned | "") cert_type="selfsigned" ;;
  [Ll] | letsencrypt) cert_type="letsencrypt" ;;
  [Uu] | upload) cert_type="custom" ;;
  *)
    echo "[Error] Invalid certificate type '$cert_choice'. Use selfsigned|letsencrypt|upload." >&2
    return 1
    ;;
  esac

  if ! _config_begin_transaction_if_needed started_txn "replace_cert_${domain}_${port_suffix}" "$CERTS_DIR" "$ACME_WEBROOT_DIR"; then
    exit 1
  fi

  # Generate the new certificate first to avoid downtime. If it fails, the existing
  # certificate remains untouched.
  local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
  SKIP_UPDATE_NGINX_CONFIG=true
  if ! add_cert "$domain" "$port_suffix" "$cert_choice" "$upload_fc" "$upload_pk"; then
    if [ "$prev_skip_update" = "true" ]; then
      SKIP_UPDATE_NGINX_CONFIG="true"
    else
      unset SKIP_UPDATE_NGINX_CONFIG
    fi
    echo "[Error] Failed to replace certificate for ${domain}_${port_suffix}; existing certificate kept intact." >&2
    _rollback_handler
  fi
  if [ "$prev_skip_update" = "true" ]; then
    SKIP_UPDATE_NGINX_CONFIG="true"
  else
    unset SKIP_UPDATE_NGINX_CONFIG
  fi

  local le_rel_cert_path="letsencrypt/live/${domain}_${port_suffix}"
  local le_pref_cert_path="certs/${le_rel_cert_path}"
  local le_shared_source_referenced=false
  if letsencrypt_source_has_remaining_consumers "$domain" "$le_rel_cert_path" "$le_pref_cert_path"; then
    le_shared_source_referenced=true
  fi

  # Clean up old provider directories only after the new cert exists. Skip the
  # freshly-written provider to avoid removing the new material.
  local removed=false
  local provider
  for provider in letsencrypt selfsigned custom; do
    [ "$provider" = "$cert_type" ] && continue
    local dir="${CERTS_DIR}/${provider}/live/${domain}_${port_suffix}"
    if [ -d "$dir" ]; then
      safe_rm_rf "$dir" "${CERTS_DIR}/${provider}/live"
      echo "[Info] Removed old ${provider} certificate directory $dir"
      removed=true
    fi
    if [ "$provider" = "letsencrypt" ]; then
      local le_archive_dir="${CERTS_DIR}/${provider}/archive"
      local le_port_archive_dir="${le_archive_dir}/${domain}_${port_suffix}"
      if [ -d "$le_port_archive_dir" ]; then
        safe_rm_rf "$le_port_archive_dir" "$le_archive_dir"
        echo "[Info] Removed Let’s Encrypt archive directory $le_port_archive_dir"
        removed=true
      fi

      local le_renewal_dir="${CERTS_DIR}/${provider}/renewal"
      local le_port_renewal_conf="${le_renewal_dir}/${domain}_${port_suffix}.conf"
      if [ -f "$le_port_renewal_conf" ]; then
        safe_rm_f "$le_port_renewal_conf" "$le_renewal_dir"
        echo "[Info] Removed Let’s Encrypt renewal config $le_port_renewal_conf"
        removed=true
      fi

      if [ "$le_shared_source_referenced" != true ]; then
        local le_live_dir="${CERTS_DIR}/${provider}/live/${domain}"
        if [ -d "$le_live_dir" ]; then
          safe_rm_rf "$le_live_dir" "${CERTS_DIR}/${provider}/live"
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
    create_backup "" "ReplaceCert_${domain}_${port_suffix}"
  fi

  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
