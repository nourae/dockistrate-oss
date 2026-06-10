# shellcheck shell=bash

function _init_backend_mtls_state() {
  local mtls_dir="${1:-}"
  _mtls_prepare_dir_for_mutation mtls_dir "$mtls_dir" || return 1
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    mkdir -p "newcerts" || exit 1
    touch "index.txt" || exit 1
    [ -f "serial" ] || echo 1000 >"serial" || exit 1
    [ -f "crlnumber" ] || echo 1000 >"crlnumber" || exit 1
    rm -f "ca.srl" || exit 1
  ) || return 1
  _write_backend_openssl_conf "$mtls_dir" >/dev/null || return 1
}
