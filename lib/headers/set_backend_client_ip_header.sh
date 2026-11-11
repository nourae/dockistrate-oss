# shellcheck shell=bash
if ! declare -F _global_settings_update_nginx_config_for_security_change >/dev/null 2>&1; then
  # shellcheck source=../global_settings/common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../global_settings" && pwd)/common.sh"
fi

function set_backend_client_ip_header() {
  local domain="${1:-}"
  local name="${2:-}"
  if [ -z "$domain" ] || [ -z "$name" ]; then
    echo "[Usage] set-backend-client-ip-header <domain> <header|off>"
    exit 1
  fi
  domain="$(normalize_domain "$domain")"
  if ! domain_exists "$domain"; then
    echo "[Error] Unknown domain '$domain'" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_backend_client_ip_header_${domain}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$BACKEND_CLIENT_IP_HEADER_FILE")" || { transaction_return_failure; exit 1; }
  if [ "$name" != "off" ]; then
    if ! is_valid_header_name "$name"; then
      echo "[Error] Invalid header name: $name" >&2
      exit 1
    fi
    echo "[Info] Set client IP header for $domain to $name"
  else
    echo "[Info] Disabled client IP header for $domain"
  fi
  state_csv_upsert_two_col_value "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$domain" "$name" || { transaction_return_failure; exit 1; }
  create_backup "" "SetBackendClientIPHeader_${domain}" || { transaction_return_failure; exit 1; }
  _global_settings_update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; exit 1; }
}
