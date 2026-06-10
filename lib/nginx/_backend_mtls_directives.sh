# shellcheck shell=bash

function _backend_mtls_directives() {
  local domain="${1:-}"
  local mtls_dir ca_file crl_path crl_file certs_root
  if ! is_valid_domain "$domain"; then
    echo "[Error] Invalid mTLS domain while rendering Nginx config: $domain" >&2
    return 1
  fi
  domain="$(normalize_domain "$domain")"
  mtls_dir="$(get_backend_mtls_dir "$domain")"
  if [ -z "$mtls_dir" ]; then
    return
  fi
  if ! normalize_mtls_dir mtls_dir "$mtls_dir"; then
    return 1
  fi
  if ! certs_root="$(_realpath_portable "$CERTS_DIR")"; then
    echo "[Error] Unable to resolve certificate root directory '${CERTS_DIR}'." >&2
    return 1
  fi

  ca_file="${mtls_dir}/ca.crt"
  ca_file="/etc/letsencrypt${ca_file#${certs_root}}"
  echo "    ssl_client_certificate ${ca_file};"

  crl_path="${mtls_dir}/ca.crl"
  if [ ! -f "$crl_path" ] && command -v _generate_backend_crl >/dev/null 2>&1; then
    _generate_backend_crl "$mtls_dir"
  fi
  if [ -f "$crl_path" ]; then
    crl_file="/etc/letsencrypt${crl_path#${certs_root}}"
    echo "    ssl_crl ${crl_file};"
  fi

  echo "    ssl_verify_client on;"
}
