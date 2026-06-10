# shellcheck shell=bash

function _generate_backend_crl() {
  local mtls_dir="${1:-}"
  _mtls_prepare_dir_for_mutation mtls_dir "$mtls_dir" || return 1
  _init_backend_mtls_state "$mtls_dir" || return 1
  local openssl_conf=""
  if ! openssl_conf="$(_write_backend_openssl_conf "$mtls_dir")"; then
    return 1
  fi
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    local tmp_crl="" old_umask=""
    old_umask="$(umask)"
    umask 077
    tmp_crl="$(mktemp ".ca.crl.tmp.XXXXXX" 2>/dev/null)" || {
      umask "$old_umask"
      echo "[Error] Unable to create temp file for ${mtls_dir}/ca.crl" >&2
      exit 1
    }
    umask "$old_umask"
    if ! openssl ca -config "$(basename "$openssl_conf")" -gencrl -out "$tmp_crl" -crldays 365 >/dev/null 2>&1; then
      echo "[Error] Failed to generate CRL for ${mtls_dir##*/}" >&2
      rm -f "$tmp_crl"
      exit 1
    fi
    chmod 644 "$tmp_crl" 2>/dev/null || true
    mv -f "$tmp_crl" "ca.crl" || {
      rm -f "$tmp_crl"
      echo "[Error] Failed to replace ${mtls_dir}/ca.crl atomically" >&2
      exit 1
    }
  )
}
