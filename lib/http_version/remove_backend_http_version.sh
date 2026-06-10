# shellcheck shell=bash

function remove_backend_http_version() {
  local domain="${1:-}"
  [ -z "$domain" ] && {
    echo "[Usage] remove-backend-http-version <domain>"
    exit 1
  }
  domain="$(normalize_domain "$domain")"
  if [ -f "$BACKEND_HTTP_FILE" ]; then
    local started_txn=false
    if ! _config_begin_transaction_if_needed started_txn "remove_backend_http_version_${domain}"; then
      exit 1
    fi
    state_csv_delete_two_col_key "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$domain"
    echo "[Info] Removed HTTP version override for $domain"
    create_backup "" "RemoveBackendHTTPVer_${domain}"
    update_nginx_config
    _config_end_transaction_if_started "$started_txn"
  fi
}
