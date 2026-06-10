# shellcheck shell=bash

function _issue_backend_client_cert() {
  local mtls_dir="${1:-}" client="${2:-}"
  _mtls_prepare_dir_for_mutation mtls_dir "$mtls_dir" || return 1
  _init_backend_mtls_state "$mtls_dir" || return 1
  local openssl_conf=""
  if ! openssl_conf="$(_write_backend_openssl_conf "$mtls_dir")"; then
    return 1
  fi
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    if ! openssl req -newkey rsa:2048 -nodes \
      -keyout "${client}.key" \
      -subj "/CN=${client}" \
      -out "${client}.csr" >/dev/null 2>&1; then
      echo "[Error] Failed to generate client certificate request for ${client}" >&2
      rm -f "${client}.csr" "${client}.key"
      exit 1
    fi
    chmod 600 "${client}.key" 2>/dev/null || true
    if ! openssl ca -batch -config "$(basename "$openssl_conf")" -in "${client}.csr" \
      -out "${client}.crt" -notext >/dev/null 2>&1; then
      echo "[Error] Failed to sign client certificate for ${client}" >&2
      rm -f "${client}.csr" "${client}.key" "${client}.crt"
      exit 1
    fi
    rm -f "${client}.csr"
  ) || return 1
  echo "[Info] Generated client certificate ${client}.crt for ${mtls_dir##*/}"
}
