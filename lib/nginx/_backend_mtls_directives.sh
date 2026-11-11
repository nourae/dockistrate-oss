# shellcheck shell=bash

function _backend_mtls_directives() {
  local domain="${1:-}"
  local mtls_dir ca_file crl_path crl_file certs_root
  if ! is_valid_domain "$domain"; then
    echo "[Error] Invalid mTLS domain while rendering Nginx config: $domain" >&2
    return 1
  fi
  domain="$(normalize_domain "$domain")"
  if ! mtls_dir="$(get_backend_mtls_dir "$domain")"; then
    return 1
  fi
  if [ -z "$mtls_dir" ]; then
    return 0
  fi
  local certificate_source_root="$CERTS_DIR"
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    certificate_source_root="${DOMAINS_DIR:-${STATE_DIR}/domains}"
  fi
  if ! certs_root="$(_realpath_portable "$certificate_source_root" && printf '.')"; then
    echo "[Error] Unable to resolve certificate root directory '${CERTS_DIR}'." >&2
    return 1
  fi
  certs_root="${certs_root%.}"

  ca_file="${mtls_dir}/ca.crt"
  ca_file="/etc/letsencrypt${ca_file#"${certs_root}"}"

  crl_path="${mtls_dir}/ca.crl"
  if [ -L "$crl_path" ] || { [ -e "$crl_path" ] && [ ! -f "$crl_path" ]; }; then
    echo "[Error] Refusing unsafe mTLS CRL for '${domain}': ${crl_path} must be a non-symlink regular file." >&2
    return 1
  fi
  if [ ! -f "$crl_path" ]; then
    if ! command -v _generate_backend_crl >/dev/null 2>&1; then
      echo "[Error] Required mTLS CRL is missing for '${domain}', and CRL generation is unavailable." >&2
      return 1
    fi
    if ! _generate_backend_crl "$mtls_dir" >/dev/null; then
      echo "[Error] Failed to generate required mTLS CRL for '${domain}'." >&2
      return 1
    fi
    if [ -L "$crl_path" ] || [ ! -f "$crl_path" ]; then
      echo "[Error] CRL generation did not create a safe regular mTLS CRL for '${domain}': ${crl_path}" >&2
      return 1
    fi
  fi

  crl_file="/etc/letsencrypt${crl_path#"${certs_root}"}"
  printf '%s\n' \
    "    ssl_client_certificate ${ca_file};" \
    "    ssl_crl ${crl_file};" \
    "    ssl_verify_client on;"
}
