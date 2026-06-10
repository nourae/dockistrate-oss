# shellcheck shell=bash

function remove_all_backend_headers() {
  local domain="${1:-}"
  if [ ! -f "$BACKEND_HEADERS_FILE" ] || [ ! -s "$BACKEND_HEADERS_FILE" ]; then
    echo "[Info] No backend headers configured."
    return
  fi

  csv_require_header "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" || return 1
  local started_txn=false
  if [ -n "$domain" ]; then
    if ! _config_begin_transaction_if_needed started_txn "remove_backend_headers_${domain}"; then
      exit 1
    fi
  else
    if ! _config_begin_transaction_if_needed started_txn "remove_all_backend_headers"; then
      exit 1
    fi
  fi

  if [ -n "$domain" ]; then
    domain="$(normalize_domain "$domain")"
    resolve_backend_domain domain "$domain" true
    if ! state_csv_has_row_by_keys "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 1 "$domain"; then
      echo "[Info] No backend headers configured for ${domain}."
      _config_end_transaction_if_started "$started_txn"
      return
    fi
    state_csv_delete_by_keys "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 1 "$domain"
    echo "[Info] Removed backend headers for ${domain}."
    create_backup "" "RemoveBackendHeaders_${domain}"
  else
    printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER" >"$BACKEND_HEADERS_FILE"
    echo "[Info] Removed all backend headers."
    create_backup "" "RemoveAllBackendHeaders"
  fi

  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
