# shellcheck shell=bash

function remove_all_headers() {
  if [ ! -f "$CUSTOM_HEADERS_FILE" ] || [ ! -s "$CUSTOM_HEADERS_FILE" ]; then
    echo "[Info] No global headers configured."
    return
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_all_headers"; then
    exit 1
  fi
  csv_require_header "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER" || return 1
  printf '%s\n' "$STATE_CUSTOM_HEADERS_HEADER" >"$CUSTOM_HEADERS_FILE"
  echo "[Info] Removed all global headers."
  create_backup "" "RemoveAllHeaders"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
