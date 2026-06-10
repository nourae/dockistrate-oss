# shellcheck shell=bash

function remove_backend_ca() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then
    echo "[Usage] remove-backend-ca <domain>"
    exit 1
  fi
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  local mtls_dir="" started_txn="false" prev_skip_update="" had_prev_skip="false"
  _resolve_backend_mtls_dir mtls_dir "$domain" || exit 1
  _mtls_begin_transaction_if_needed started_txn "remove_backend_ca_${domain}" "$BACKEND_MTLS_FILE" "$mtls_dir" || exit 1
  if [ "${SKIP_UPDATE_NGINX_CONFIG+x}" = "x" ]; then
    had_prev_skip="true"
    prev_skip_update="$SKIP_UPDATE_NGINX_CONFIG"
  fi
  SKIP_UPDATE_NGINX_CONFIG=true
  if ! disable_backend_mtls "$domain" >/dev/null; then
    _mtls_restore_skip_update_nginx_config "$had_prev_skip" "$prev_skip_update"
    return 1
  fi
  if [ -n "$mtls_dir" ] && ([ -e "$mtls_dir" ] || [ -L "$mtls_dir" ]); then
    _mtls_remove_dir_if_exists "$mtls_dir" || {
      _mtls_restore_skip_update_nginx_config "$had_prev_skip" "$prev_skip_update"
      return 1
    }
  fi
  _mtls_restore_skip_update_nginx_config "$had_prev_skip" "$prev_skip_update"
  update_nginx_config || return 1
  _mtls_end_transaction_if_started "$started_txn"
  echo "[Info] Removed CA and client certificates for $domain"
}

# Replace a client certificate
