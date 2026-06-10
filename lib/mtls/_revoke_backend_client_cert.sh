# shellcheck shell=bash

function _normalize_backend_client_cert_serial() {
  local serial="${1:-}"
  serial="${serial#serial=}"
  serial="$(printf '%s' "$serial" | tr '[:lower:]' '[:upper:]')"
  while [ "${#serial}" -gt 1 ] && [ "${serial#0}" != "$serial" ]; do
    serial="${serial#0}"
  done
  printf '%s' "$serial"
}

function _backend_client_cert_serial_is_revoked() {
  local mtls_dir="${1:-}" crt_file="${2:-}"
  local serial="" normalized_serial=""
  local line_status="" line_expiry="" line_revocation="" line_serial="" line_filename="" line_subject=""
  local index_file="${mtls_dir}/index.txt"

  [ -f "$crt_file" ] || return 1
  [ -f "$index_file" ] || return 1

  if ! serial="$(openssl x509 -in "$crt_file" -serial -noout 2>/dev/null)"; then
    return 1
  fi
  normalized_serial="$(_normalize_backend_client_cert_serial "$serial")"

  while IFS="$(printf '\t')" read -r line_status line_expiry line_revocation line_serial line_filename line_subject; do
    [ "$line_status" = "R" ] || continue
    [ -n "$line_serial" ] || continue
    if [ "$(_normalize_backend_client_cert_serial "$line_serial")" = "$normalized_serial" ]; then
      return 0
    fi
  done <"$index_file"

  return 1
}

function _revoke_backend_client_cert() {
  local mtls_dir="${1:-}" client="${2:-}" remove_files="${3:-false}"
  _mtls_prepare_dir_for_mutation mtls_dir "$mtls_dir" || return 1
  _init_backend_mtls_state "$mtls_dir" || return 1
  local openssl_conf=""
  if ! openssl_conf="$(_write_backend_openssl_conf "$mtls_dir")"; then
    return 1
  fi
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    if [ -f "${client}.crt" ]; then
      if ! _backend_client_cert_serial_is_revoked "." "${client}.crt"; then
        if ! openssl ca -config "$(basename "$openssl_conf")" -revoke "${client}.crt" -crl_reason superseded >/dev/null 2>&1; then
          echo "[Error] Failed to revoke client certificate ${client} for ${mtls_dir##*/}" >&2
          exit 1
        fi
      fi
    fi
  ) || return 1
  _generate_backend_crl "$mtls_dir" || return 1
  if [ "$remove_files" = true ]; then
    _mtls_rm_f "$mtls_dir" "${client}.crt" "${client}.key" || return 1
  fi
}
