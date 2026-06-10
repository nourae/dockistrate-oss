# shellcheck shell=bash

function _mtls_begin_transaction_if_needed() {
  local __started_var="${1:-}" desc="${2:-}"
  shift 2 || true
  _config_begin_transaction_if_needed "$__started_var" "$desc" "$@"
}

function _mtls_end_transaction_if_started() {
  _config_end_transaction_if_started "${1:-false}"
}

function _mtls_restore_skip_update_nginx_config() {
  local had_prev_skip="${1:-false}" prev_skip_update="${2-}"
  if [ "$had_prev_skip" = "true" ]; then
    SKIP_UPDATE_NGINX_CONFIG="$prev_skip_update"
  else
    unset SKIP_UPDATE_NGINX_CONFIG
  fi
}

function _mtls_normalize_valid_domain() {
  local __out="${1:-}" domain="${2:-}" normalized_value=""
  require_valid_var_name "$__out" || return 1
  require_valid_domain "$domain" return || return 1
  normalized_value="$(normalize_domain "$domain")"
  printf -v "$__out" '%s' "$normalized_value"
}

function _resolve_backend_mtls_dir() {
  local __out="${1:-}" domain="${2:-}" normalized_domain="" original_mtls_dir="" resolved_mtls_dir=""
  require_valid_var_name "$__out" || return 1
  _mtls_normalize_valid_domain normalized_domain "$domain" || return 1

  resolved_mtls_dir="$(get_backend_mtls_dir "$normalized_domain")"
  if [ -z "$resolved_mtls_dir" ]; then
    echo "[Error] mTLS not enabled for $normalized_domain" >&2
    return 1
  fi
  _mtls_original_dir_path original_mtls_dir "$resolved_mtls_dir" || return 1
  _mtls_reject_original_dir_symlink "$original_mtls_dir" "mTLS backend directory" || return 1
  if ! normalize_mtls_dir resolved_mtls_dir "$original_mtls_dir"; then
    return 1
  fi
  if [ "$resolved_mtls_dir" != "$original_mtls_dir" ]; then
    echo "[Error] Refusing to use symlinked mTLS backend directory: ${original_mtls_dir}" >&2
    return 1
  fi

  printf -v "$__out" '%s' "$resolved_mtls_dir"
}

function _mtls_reject_unsafe_relative_name() {
  local name="${1:-}" label="${2:-mTLS file}"
  case "$name" in
  "" | "." | ".." | */*)
    echo "[Error] Refusing unsafe ${label} name: ${name}" >&2
    return 1
    ;;
  esac
}

function _mtls_original_dir_path() {
  local __out="${1:-}" __mtls_orig_path_in="${2:-}" __mtls_orig_root="" __mtls_orig_root_real="" __mtls_orig_normalized=""
  require_valid_var_name "$__out" || return 1
  if [ -z "$__mtls_orig_path_in" ]; then
    echo "[Error] mTLS directory path required." >&2
    return 1
  fi

  __mtls_orig_root="${CERTS_DIR%/}/mtls"
  guard_mtls_root_dir || return 1
  __mtls_orig_root_real="$(_realpath_portable "$__mtls_orig_root")" || {
    echo "[Error] Unable to resolve mTLS root directory '${__mtls_orig_root}'." >&2
    return 1
  }
  __mtls_orig_normalized="$(_normalize_delete_target_path "$__mtls_orig_path_in")" || {
    echo "[Error] Unable to resolve mTLS directory '${__mtls_orig_path_in}'." >&2
    return 1
  }

  case "$__mtls_orig_normalized" in
  "$__mtls_orig_root_real" | "$__mtls_orig_root_real"/*) ;;
  *)
    echo "[Error] mTLS directory '${__mtls_orig_path_in}' must reside within '${__mtls_orig_root_real}'." >&2
    return 1
    ;;
  esac

  printf -v "$__out" '%s' "$__mtls_orig_normalized"
}

function _mtls_reject_original_dir_symlink() {
  local mtls_dir="${1:-}" label="${2:-mTLS directory}" original_mtls_dir=""
  _mtls_original_dir_path original_mtls_dir "$mtls_dir" || return 1
  if [ -L "$original_mtls_dir" ]; then
    echo "[Error] Refusing to use symlinked ${label}: ${original_mtls_dir}" >&2
    return 1
  fi
}

function _mtls_prepare_dir_for_mutation() {
  local __out="${1:-}" mtls_dir="${2:-}" original_mtls_dir="" resolved_mtls_dir="" old_umask=""
  require_valid_var_name "$__out" || return 1
  _mtls_original_dir_path original_mtls_dir "$mtls_dir" || return 1
  _mtls_reject_original_dir_symlink "$original_mtls_dir" || return 1
  old_umask="$(umask)"
  umask 077
  mkdir -p "$original_mtls_dir" || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  _mtls_reject_original_dir_symlink "$original_mtls_dir" || return 1
  normalize_mtls_dir resolved_mtls_dir "$original_mtls_dir" || return 1
  if [ "$resolved_mtls_dir" != "$original_mtls_dir" ]; then
    echo "[Error] Refusing mTLS directory symlink swap during mutation: ${original_mtls_dir}" >&2
    return 1
  fi
  printf -v "$__out" '%s' "$resolved_mtls_dir"
}

function _mtls_cd_guarded_dir() {
  local mtls_dir="${1:-}" original_mtls_dir="" resolved_mtls_dir="" actual="" rechecked_mtls_dir=""
  _mtls_original_dir_path original_mtls_dir "$mtls_dir" || return 1
  _mtls_reject_original_dir_symlink "$original_mtls_dir" || return 1
  normalize_mtls_dir resolved_mtls_dir "$original_mtls_dir" || return 1
  if [ "$resolved_mtls_dir" != "$original_mtls_dir" ]; then
    echo "[Error] Refusing to use symlinked mTLS directory: ${original_mtls_dir}" >&2
    return 1
  fi
  if [ ! -d "$original_mtls_dir" ]; then
    echo "[Error] mTLS directory does not exist: ${original_mtls_dir}" >&2
    return 1
  fi
  _mtls_reject_original_dir_symlink "$original_mtls_dir" || return 1
  cd -P "$original_mtls_dir" 2>/dev/null || {
    echo "[Error] Unable to enter mTLS directory: ${original_mtls_dir}" >&2
    return 1
  }
  guard_mtls_root_dir || return 1
  actual="$(pwd -P)" || return 1
  normalize_mtls_dir rechecked_mtls_dir "$original_mtls_dir" || return 1
  if [ "$actual" != "$rechecked_mtls_dir" ] || [ "$rechecked_mtls_dir" != "$original_mtls_dir" ]; then
    echo "[Error] Refusing mTLS directory swap during mutation: ${original_mtls_dir}" >&2
    return 1
  fi
}

function _mtls_chmod_file() {
  local mtls_dir="${1:-}" file_name="${2:-}" mode="${3:-600}"
  _mtls_reject_unsafe_relative_name "$file_name" "mTLS file" || return 1
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    [ -f "$file_name" ] || exit 0
    chmod "$mode" "$file_name" 2>/dev/null || true
  )
}

function _mtls_require_client_cert_files() {
  local mtls_dir="${1:-}" client="${2:-}"
  _mtls_reject_unsafe_relative_name "${client}.crt" "mTLS client certificate" || return 1
  _mtls_reject_unsafe_relative_name "${client}.key" "mTLS client key" || return 1
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    if [ ! -f "${client}.crt" ] || [ ! -f "${client}.key" ]; then
      echo "[Error] Certificate or key missing for $client" >&2
      exit 1
    fi
  )
}

function _mtls_write_client_p12() {
  local mtls_dir="${1:-}" client="${2:-}" password="${3:-}"
  _mtls_reject_unsafe_relative_name "${client}.p12" "mTLS PKCS#12 file" || return 1
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    local tmp_p12="" old_umask=""
    if [ ! -f "${client}.crt" ] || [ ! -f "${client}.key" ]; then
      echo "[Error] Certificate or key missing for $client" >&2
      exit 1
    fi
    old_umask="$(umask)"
    umask 077
    tmp_p12="$(mktemp ".${client}.p12.tmp.XXXXXX" 2>/dev/null)" || {
      umask "$old_umask"
      echo "[Error] Unable to create temp file for ${mtls_dir}/${client}.p12" >&2
      exit 1
    }
    umask "$old_umask"
    if ! printf '%s' "$password" | openssl pkcs12 -export -inkey "${client}.key" -in "${client}.crt" \
      -certfile "ca.crt" -name "$client" -out "$tmp_p12" -passout stdin >/dev/null 2>&1; then
      rm -f "$tmp_p12"
      echo "[Error] Failed to generate PKCS#12 bundle" >&2
      exit 1
    fi
    chmod 600 "$tmp_p12" 2>/dev/null || {
      rm -f "$tmp_p12"
      echo "[Error] Failed to set mode 600 on temp file ${tmp_p12}" >&2
      exit 1
    }
    mv -f "$tmp_p12" "${client}.p12" || {
      rm -f "$tmp_p12"
      echo "[Error] Failed to finalize PKCS#12 bundle" >&2
      exit 1
    }
    chmod 600 "${client}.p12" 2>/dev/null || true
  )
}

function _mtls_rm_f() {
  local mtls_dir="${1:-}" file_name=""
  shift || true
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    for file_name in "$@"; do
      _mtls_reject_unsafe_relative_name "$file_name" "mTLS file" || exit 1
      rm -f "$file_name" || exit 1
    done
  )
}

function _mtls_remove_ca_material() {
  local mtls_dir="${1:-}"
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    rm -f ./*.crt ./*.key ./index.txt* ./serial ./crlnumber ./ca.srl ./ca.crl ./openssl.cnf || exit 1
    rm -rf ./newcerts || exit 1
  )
}

function _mtls_remove_dir_if_exists() {
  local mtls_dir="${1:-}" original_mtls_dir="" mtls_root="" mtls_root_real="" parent_dir="" dir_name=""
  _mtls_original_dir_path original_mtls_dir "$mtls_dir" || return 1
  _mtls_reject_original_dir_symlink "$original_mtls_dir" || return 1
  mtls_root="${CERTS_DIR%/}/mtls"
  guard_mtls_root_dir || return 1
  mtls_root_real="$(_realpath_portable "$mtls_root")" || {
    echo "[Error] Unable to resolve mTLS root directory '${mtls_root}'." >&2
    return 1
  }
  case "$original_mtls_dir" in
  "$mtls_root_real"/*) ;;
  *)
    echo "[Error] Refusing to remove mTLS directory outside mTLS root: ${mtls_dir}" >&2
    return 1
    ;;
  esac
  parent_dir="${original_mtls_dir%/*}"
  if [ "$parent_dir" != "$mtls_root_real" ]; then
    echo "[Error] Refusing to remove nested mTLS directory: ${mtls_dir}" >&2
    return 1
  fi
  dir_name="${original_mtls_dir##*/}"
  _mtls_reject_unsafe_relative_name "$dir_name" "mTLS directory" || return 1
  (
    _mtls_cd_guarded_dir "$mtls_root_real" || exit 1
    if [ -L "$dir_name" ]; then
      echo "[Error] Refusing to remove symlinked mTLS directory: ${original_mtls_dir}" >&2
      exit 1
    fi
    rm -rf "$dir_name" || exit 1
  )
}

function _generate_backend_ca() {
  local mtls_dir="${1:-}" domain="${2:-}"
  _mtls_prepare_dir_for_mutation mtls_dir "$mtls_dir" || return 1
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
      -keyout "ca.key" \
      -out "ca.crt" \
      -subj "/CN=${domain} CA" >/dev/null 2>&1; then
      echo "[Error] Failed to generate backend CA for ${domain}" >&2
      rm -f "ca.key" "ca.crt"
      exit 1
    fi
    chmod 600 "ca.key" 2>/dev/null || true
  )
}
