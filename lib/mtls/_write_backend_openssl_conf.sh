# shellcheck shell=bash

function _write_backend_openssl_conf() {
  local mtls_dir="${1:-}"
  _mtls_prepare_dir_for_mutation mtls_dir "$mtls_dir" || return 1
  local openssl_conf="${mtls_dir}/openssl.cnf"

  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    local tmp_conf="" old_umask=""
    mkdir -p "newcerts" || exit 1
    old_umask="$(umask)"
    umask 077
    tmp_conf="$(mktemp ".openssl.cnf.tmp.XXXXXX" 2>/dev/null)" || {
      umask "$old_umask"
      echo "[Error] Unable to create temp file for ${openssl_conf}" >&2
      exit 1
    }
    umask "$old_umask"
    {
      printf '%s\n' '[ ca ]'
      printf '%s\n' 'default_ca = mtls_ca'
      printf '\n'
      printf '%s\n' '[ mtls_ca ]'
      printf '%s\n' 'dir = .'
      printf '%s\n' 'certs = .'
      printf '%s\n' 'crl_dir = .'
      printf '%s\n' 'database = ./index.txt'
      printf '%s\n' 'new_certs_dir = ./newcerts'
      printf '%s\n' 'serial = ./serial'
      printf '%s\n' 'crlnumber = ./crlnumber'
      printf '%s\n' 'RANDFILE = ./.rnd'
      printf '%s\n' 'certificate = ./ca.crt'
      printf '%s\n' 'private_key = ./ca.key'
      printf '%s\n' 'default_md = sha256'
      printf '%s\n' 'policy = mtls_policy'
      printf '%s\n' 'x509_extensions = usr_cert'
      printf '%s\n' 'default_days = 365'
      printf '%s\n' 'default_crl_days = 30'
      printf '%s\n' 'unique_subject = no'
      printf '\n'
      printf '%s\n' '[ mtls_policy ]'
      printf '%s\n' 'commonName = supplied'
      printf '\n'
      printf '%s\n' '[ usr_cert ]'
      printf '%s\n' 'basicConstraints = CA:FALSE'
      printf '%s\n' 'keyUsage = digitalSignature,keyEncipherment'
      printf '%s\n' 'extendedKeyUsage = clientAuth'
      printf '%s\n' 'subjectKeyIdentifier = hash'
      printf '%s\n' 'authorityKeyIdentifier = keyid,issuer'
      printf '\n'
      printf '%s\n' '[ crl_ext ]'
      printf '%s\n' 'authorityKeyIdentifier = keyid:always'
      printf '%s\n' 'basicConstraints = CA:false'
    } >"$tmp_conf" || {
      rm -f "$tmp_conf"
      exit 1
    }
    chmod 600 "$tmp_conf" 2>/dev/null || {
      rm -f "$tmp_conf"
      echo "[Error] Failed to set mode 600 on temp file ${tmp_conf}" >&2
      exit 1
    }
    mv -f "$tmp_conf" "openssl.cnf" || {
      rm -f "$tmp_conf"
      echo "[Error] Failed to replace ${openssl_conf} atomically" >&2
      exit 1
    }
  ) || return 1
  echo "$openssl_conf"
}
