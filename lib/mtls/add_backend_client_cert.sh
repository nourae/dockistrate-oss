# shellcheck shell=bash

function add_backend_client_cert() {
  local domain="${1:-}" client="${2:-}"
  if [ -z "$domain" ] || [ -z "$client" ]; then
    echo "[Usage] add-backend-client-cert <domain> <client_name>"
    exit 1
  fi
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  if ! is_valid_client_name "$client"; then
    echo "[Error] Invalid client name: '$client'. Use only alphanumeric characters, hyphens, underscores, and dots." >&2
    exit 1
  fi
  local mtls_dir="" started_txn="false"
  _resolve_backend_mtls_dir mtls_dir "$domain" || exit 1
  _mtls_begin_transaction_if_needed started_txn "add_backend_client_cert_${domain}_${client}" "$mtls_dir" || exit 1
  _issue_backend_client_cert "$mtls_dir" "$client" || return 1
  _generate_backend_crl "$mtls_dir" || return 1
  update_nginx_config || return 1
  _mtls_end_transaction_if_started "$started_txn"
}
