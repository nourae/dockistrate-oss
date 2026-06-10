# shellcheck shell=bash

function remove_backend_header() {
  local domain="${1:-}" type="${2:-}" name="${3:-}"
  if [ -z "$domain" ] || [ -z "$type" ] || [ -z "$name" ]; then
    echo "[Usage] remove-backend-header <domain> <request|response> <name>"
    exit 1
  fi
  require_valid_domain "$domain"
  domain="$(normalize_domain "$domain")"
  if [[ "$type" != "request" && "$type" != "response" ]]; then
    echo "[Error] Type must be 'request' or 'response'" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_backend_header_${domain}_${type}_${name}"; then
    exit 1
  fi
  state_csv_delete_by_keys "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 3 "$domain" "$type" "$name"
  echo "[Info] Removed $type header $name for $domain"
  create_backup "" "RemoveBackendHeader_${domain}_${name}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
