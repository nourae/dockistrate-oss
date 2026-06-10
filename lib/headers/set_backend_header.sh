# shellcheck shell=bash

function set_backend_header() {
  local domain="${1:-}" type="${2:-}" name="${3:-}" value="${4:-}"
  if [ -z "$domain" ] || [ -z "$type" ] || [ -z "$name" ] || [ -z "$value" ]; then
    echo "[Usage] add-backend-header <domain> <request|response> <name> <value>"
    exit 1
  fi
  domain="$(normalize_domain "$domain")"
  if [[ "$type" != "request" && "$type" != "response" ]]; then
    echo "[Error] Type must be 'request' or 'response'" >&2
    exit 1
  fi
  if ! domain_exists "$domain"; then
    echo "[Error] Unknown domain '$domain'" >&2
    exit 1
  fi
  if ! is_valid_header_name "$name"; then
    echo "[Error] Invalid header name: $name" >&2
    exit 1
  fi
  if ! is_valid_header_value "$value"; then
    echo "[Error] Invalid header value: control characters are not allowed" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_backend_header_${domain}_${type}_${name}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$BACKEND_HEADERS_FILE")"
  state_csv_upsert_row_by_keys \
    "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 3 \
    "$domain" "$type" "$name" \
    -- "$domain" "$type" "$name" "$value"
  echo "[Info] Set $type header $name for $domain"
  create_backup "" "SetBackendHeader_${domain}_${name}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
