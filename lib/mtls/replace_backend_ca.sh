# shellcheck shell=bash

function replace_backend_ca() {
  local domain="${1:-}" # input-validation-audit: ignore
  if [ -z "$domain" ]; then
    echo "[Usage] replace-backend-ca <domain>"
    exit 1
  fi
  # Domain is validated before persisted mTLS directory lookup or destructive CA rotation.
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  local mtls_dir=""
  _resolve_backend_mtls_dir mtls_dir "$domain" || exit 1
  local started_txn="false"
  _mtls_begin_transaction_if_needed started_txn "replace_backend_ca_${domain}" "$mtls_dir" || exit 1
  _mtls_remove_ca_material "$mtls_dir" || return 1
  _generate_backend_ca "$mtls_dir" "$domain" || return 1
  _init_backend_mtls_state "$mtls_dir" || return 1
  _generate_backend_crl "$mtls_dir" || return 1
  update_nginx_config || return 1
  _mtls_end_transaction_if_started "$started_txn"
  echo "[Info] Replaced CA for $domain; existing client certificates removed"
}

# Remove the CA and all client certificates for a backend
