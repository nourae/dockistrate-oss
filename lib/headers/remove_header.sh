# shellcheck shell=bash

function remove_header() {
  local type="${1:-}" name="${2:-}"
  if [ -z "$type" ] || [ -z "$name" ]; then
    echo "[Usage] remove-header <request|response> <name>"
    exit 1
  fi
  if [[ "$type" != "request" && "$type" != "response" ]]; then
    echo "[Error] Type must be 'request' or 'response'" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_header_${type}_${name}"; then
    exit 1
  fi
  _header_mutate_file "$CUSTOM_HEADERS_FILE" global remove "" "$type" "$name" || return 1
  echo "[Info] Removed global $type header $name"
  create_backup "" "RemoveHeader_${name}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
