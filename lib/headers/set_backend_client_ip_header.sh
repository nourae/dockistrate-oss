# shellcheck shell=bash

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
  mkdir -p "$(dirname "$BACKEND_CLIENT_IP_HEADER_FILE")"
  if [ "$name" != "off" ]; then
    if ! is_valid_header_name "$name"; then
      echo "[Error] Invalid header name: $name" >&2
      exit 1
    fi
    echo "[Info] Set client IP header for $domain to $name"
  else
    echo "[Info] Disabled client IP header for $domain"
  fi
  state_csv_upsert_two_col_value "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$domain" "$name"
  create_backup "" "SetBackendClientIPHeader_${domain}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
