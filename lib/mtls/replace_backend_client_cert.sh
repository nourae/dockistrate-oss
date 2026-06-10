# shellcheck shell=bash

function replace_backend_client_cert() {
  local domain="${1:-}" client="${2:-}"
  if [ -z "$domain" ] || [ -z "$client" ]; then
    echo "[Usage] replace-backend-client-cert <domain> <client_name>"
    exit 1
  fi
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  if ! is_valid_client_name "$client"; then
    echo "[Error] Invalid client name: '$client'. Use only alphanumeric characters, hyphens, underscores, and dots." >&2
    exit 1
  fi
  local mtls_dir="" started_txn="false" prev_skip_update="" had_prev_skip="false"
  _resolve_backend_mtls_dir mtls_dir "$domain" || exit 1
  _mtls_begin_transaction_if_needed started_txn "replace_backend_client_cert_${domain}_${client}" "$mtls_dir" || exit 1
  if [ "${SKIP_UPDATE_NGINX_CONFIG+x}" = "x" ]; then
    had_prev_skip="true"
    prev_skip_update="$SKIP_UPDATE_NGINX_CONFIG"
  fi
  SKIP_UPDATE_NGINX_CONFIG=true
  if ! remove_backend_client_cert "$domain" "$client" >/dev/null; then
    _mtls_restore_skip_update_nginx_config "$had_prev_skip" "$prev_skip_update"
    return 1
  fi
  if ! add_backend_client_cert "$domain" "$client"; then
    _mtls_restore_skip_update_nginx_config "$had_prev_skip" "$prev_skip_update"
    return 1
  fi
  _mtls_restore_skip_update_nginx_config "$had_prev_skip" "$prev_skip_update"
  update_nginx_config || return 1
  _mtls_end_transaction_if_started "$started_txn"
}

# Export a client certificate as a password-protected PKCS#12 bundle
