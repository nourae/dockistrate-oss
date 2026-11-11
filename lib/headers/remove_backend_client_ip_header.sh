# shellcheck shell=bash
if ! declare -F _global_settings_update_nginx_config_for_security_change >/dev/null 2>&1; then
  # shellcheck source=../global_settings/common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../global_settings" && pwd)/common.sh"
fi

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
    state_csv_delete_two_col_key "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$domain" || { transaction_return_failure; exit 1; }
    echo "[Info] Removed client IP header override for $domain"
    create_backup "" "RemoveBackendClientIPHeader_${domain}" || { transaction_return_failure; exit 1; }
    _global_settings_update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
    _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; exit 1; }
  fi
}

#--------------------------------------
# Global proxy IP header
#--------------------------------------
