# shellcheck shell=bash

function disable_backend_mtls() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then
    echo "[Usage] disable-backend-mtls <domain>"
    exit 1
  fi
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  if [ -f "$BACKEND_MTLS_FILE" ]; then
    local started_txn="false"
    _mtls_begin_transaction_if_needed started_txn "disable_backend_mtls_${domain}" "$BACKEND_MTLS_FILE" || return 1
    state_csv_delete_two_col_key "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$domain" || return 1
    update_nginx_config || return 1
    _mtls_end_transaction_if_started "$started_txn"
    echo "[Info] Disabled mTLS for $domain"
  fi
}
