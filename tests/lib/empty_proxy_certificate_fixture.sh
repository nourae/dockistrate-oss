# shellcheck shell=bash

# Direct-source factory fixtures isolate image/TLS-keylog launch ordering and
# post-launch status. Their unrelated certificate boundary is an empty real
# directory; certificate selection, verification, and runtime convergence are
# exercised by nginx_certificate_projection{,_runtime}.sh.
function _nginx_prepare_certificate_projection() {
  local fixture_projection="${tmp_dir}/proxy_certs/empty-generation"
  mkdir -p "$fixture_projection" || return 1
  printf -v "$1" '%s' "$fixture_projection"
}

function _nginx_verify_certificate_projection() {
  [ "${1:-}" = "${tmp_dir}/proxy_certs/empty-generation" ] &&
    [ -d "${1:-}" ] && [ ! -L "${1:-}" ]
}
