# shellcheck shell=bash

function remove_backend_client_ip_header() {
  local domain="${1:-}"
  [ -z "$domain" ] && {
    echo "[Usage] remove-backend-client-ip-header <domain>"
    exit 1
  }
  domain="$(normalize_domain "$domain")"
  if [ -f "$BACKEND_CLIENT_IP_HEADER_FILE" ]; then
    local started_txn=false
    if ! _config_begin_transaction_if_needed started_txn "remove_backend_client_ip_header_${domain}"; then
      exit 1
    fi
    state_csv_delete_two_col_key "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$domain"
    echo "[Info] Removed client IP header override for $domain"
    create_backup "" "RemoveBackendClientIPHeader_${domain}"
    update_nginx_config
    _config_end_transaction_if_started "$started_txn"
  fi
}

#--------------------------------------
# Global proxy IP header
#--------------------------------------
