# shellcheck shell=bash

function set_header() {
  local type="${1:-}" name="${2:-}" value="${3:-}"
  if [ -z "$type" ] || [ -z "$name" ] || [ -z "$value" ]; then
    echo "[Usage] add-header <request|response> <name> <value>"
    exit 1
  fi
  if [[ "$type" != "request" && "$type" != "response" ]]; then
    echo "[Error] Type must be 'request' or 'response'" >&2
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
  if ! _config_begin_transaction_if_needed started_txn "set_header_${type}_${name}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$CUSTOM_HEADERS_FILE")"
  _header_mutate_file "$CUSTOM_HEADERS_FILE" global set "" "$type" "$name" "$value" || return 1
  echo "[Info] Set global $type header $name"
  create_backup "" "SetHeader_${name}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
