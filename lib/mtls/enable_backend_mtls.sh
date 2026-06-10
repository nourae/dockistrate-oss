# shellcheck shell=bash

function enable_backend_mtls() {
  local domain="${1:-}"
  local client="${2:-}"
  if [ -z "$domain" ]; then
    echo "[Usage] enable-backend-mtls <domain> [client_name]"
    exit 1
  fi
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  if ! domain_exists "$domain"; then
    echo "[Error] Domain '$domain' not found." >&2
    exit 1
  fi
  if [ -n "$client" ] && ! is_valid_client_name "$client"; then
    echo "[Error] Invalid client name: '$client'. Use only alphanumeric characters, hyphens, underscores, and dots." >&2
    exit 1
  fi
  local mtls_root="${CERTS_DIR%/}/mtls" mtls_dir="" started_txn="false"
  ensure_mtls_root_dir || return 1
  _mtls_original_dir_path mtls_dir "${mtls_root}/${domain}" || return 1
  _mtls_reject_original_dir_symlink "$mtls_dir" "mTLS backend directory" || return 1
  _mtls_begin_transaction_if_needed started_txn "enable_backend_mtls_${domain}" "$BACKEND_MTLS_FILE" "$mtls_dir" || exit 1
  if [ ! -f "${mtls_dir}/ca.crt" ]; then
    _generate_backend_ca "$mtls_dir" "$domain" || return 1
  fi
  _mtls_chmod_file "$mtls_dir" "ca.key" 600 || return 1
  _init_backend_mtls_state "$mtls_dir" || return 1
  mkdir -p "$(dirname "$BACKEND_MTLS_FILE")" || return 1
  state_csv_upsert_two_col_value "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$domain" "$mtls_dir" || return 1
  if [ -n "$client" ]; then
    _issue_backend_client_cert "$mtls_dir" "$client" || return 1
  fi
  _generate_backend_crl "$mtls_dir" || return 1
  update_nginx_config || return 1
  _mtls_end_transaction_if_started "$started_txn"
}
