# shellcheck shell=bash

function _init_backend_mtls_state() {
  local mtls_dir="${1:-}" mode="${2:-existing}"
  case "$mode" in
  existing) _mtls_validate_authority_state "$mtls_dir" || return 1 ;;
  regenerate) _mtls_validate_authority_state "$mtls_dir" regenerate || return 1 ;;
  fresh) ;;
  *) return 1 ;;
  esac
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    if [ -L newcerts ] || { [ -e newcerts ] && [ ! -d newcerts ]; }; then
      _mtls_state_error 'newcerts must be a non-symlink directory.'; exit 1
    fi
    if [ "$mode" = fresh ]; then
      _mtls_validate_ca_pair || exit 1
      local file=""
      for file in index.txt serial crlnumber ca.crl; do
        if [ -e "$file" ] || [ -L "$file" ]; then
          _mtls_state_error "Refusing to initialize existing $file."; exit 1
        fi
      done
      # Only an explicit new authority gets an empty database and counters.
      # Noclobber also rejects a leaf that appears after the absence check.
      (
        set -C
        umask 077
        : >index.txt && printf '1000\n' >serial && printf '1000\n' >crlnumber
      ) || exit 1
    fi
    mkdir -p "newcerts" || exit 1
  ) || return 1
  _write_backend_openssl_conf "$mtls_dir" >/dev/null || return 1
}
