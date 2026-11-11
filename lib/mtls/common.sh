# shellcheck shell=bash

function _mtls_begin_transaction_if_needed() {
  local __started_var="${1:-}" desc="${2:-}"
  shift 2 || true
  _config_begin_transaction_if_needed "$__started_var" "$desc" "$@"
}

function _mtls_end_transaction_if_started() {
  _config_end_transaction_if_started "${1:-false}"
}

function _mtls_cancel_started_transaction_before_mutation() {
  if ! transaction_is_active; then
    return 0
  fi
  if ! declare -F _transaction_clear_installed_traps >/dev/null 2>&1 ||
    ! declare -F _begin_transaction_cleanup_failed_start >/dev/null 2>&1; then
    echo "[Error] Unable to cancel mTLS cleanup transaction safely." >&2
    return 1
  fi

  _transaction_clear_installed_traps
  _begin_transaction_cleanup_failed_start
}

function _mtls_restore_skip_update_nginx_config() {
  local had_prev_skip="${1:-false}" prev_skip_update="${2-}"
  if declare -F pop_skip_update_nginx_config >/dev/null 2>&1; then
    if [ "$had_prev_skip" = "true" ]; then
      pop_skip_update_nginx_config "$prev_skip_update"
    else
      pop_skip_update_nginx_config "__dockistrate_unset__"
    fi
    return 0
  fi
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

function _mtls_validate_owned_dir() {
  local __out="${1:-}" owner_domain="${2:-}" path_in="${3:-}"
  local __mtls_owned_domain="" __mtls_owned_root="" __mtls_owned_root_real=""
  local __mtls_owned_expected="" __mtls_owned_original="" __mtls_owned_resolved=""
  require_valid_var_name "$__out" || return 1
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    _domain_mtls_resolve "$__out" "$path_in" "$owner_domain"
    return $?
  fi
  if [[ "$owner_domain" =~ [[:cntrl:]] ]]; then
    echo "[Error] mTLS owner domain contains control characters." >&2
    return 1
  fi
  _mtls_normalize_valid_domain __mtls_owned_domain "$owner_domain" || return 1
  if [ -z "$path_in" ]; then
    echo "[Error] mTLS directory path required for ${__mtls_owned_domain}." >&2
    return 1
  fi
  if [[ "$path_in" =~ [[:cntrl:]] ]]; then
    echo "[Error] mTLS directory path for '${__mtls_owned_domain}' contains control characters." >&2
    return 1
  fi

  __mtls_owned_root="${CERTS_DIR%/}/mtls"
  guard_mtls_root_dir || return 1
  if [ ! -d "$__mtls_owned_root" ]; then
    echo "[Error] mTLS root is not a physical directory: ${__mtls_owned_root}" >&2
    return 1
  fi
  __mtls_owned_root_real="$(_realpath_portable "$__mtls_owned_root" && printf '.')" || {
    echo "[Error] Unable to resolve mTLS root directory '${__mtls_owned_root}'." >&2
    return 1
  }
  __mtls_owned_root_real="${__mtls_owned_root_real%.}"
  __mtls_owned_expected="${__mtls_owned_root_real}/${__mtls_owned_domain}"

  _mtls_original_dir_path __mtls_owned_original "$path_in" || return 1
  if [ "$__mtls_owned_original" != "$__mtls_owned_expected" ]; then
    echo "[Error] mTLS directory for '${__mtls_owned_domain}' must be its owned direct child '${__mtls_owned_expected}', got '${path_in}'." >&2
    return 1
  fi
  _mtls_reject_original_dir_symlink "$__mtls_owned_original" "mTLS backend directory for '${__mtls_owned_domain}'" || return 1
  if [ -e "$__mtls_owned_original" ]; then
    if [ ! -d "$__mtls_owned_original" ]; then
      echo "[Error] mTLS path for '${__mtls_owned_domain}' is not a directory: ${path_in}" >&2
      return 1
    fi
    normalize_mtls_dir __mtls_owned_resolved "$__mtls_owned_original" || return 1
  else
    __mtls_owned_resolved="$__mtls_owned_original"
  fi
  if [ "$__mtls_owned_resolved" != "$__mtls_owned_expected" ]; then
    echo "[Error] Refusing mismatched or symlinked mTLS backend directory for '${__mtls_owned_domain}': ${path_in}" >&2
    return 1
  fi

  printf -v "$__out" '%s' "$__mtls_owned_resolved"
}

function _mtls_validate_owned_dir_for_cleanup() {
  local __out="${1:-}" owner_domain="${2:-}" path_in="${3:-}"
  local __mtls_cleanup_domain="" __mtls_cleanup_root="" __mtls_cleanup_root_cmp=""
  local __mtls_cleanup_expected="" __mtls_cleanup_expected_cmp="" __mtls_cleanup_path_cmp=""
  require_valid_var_name "$__out" || return 1
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    _domain_mtls_resolve "$__out" "$path_in" "$owner_domain"
    return $?
  fi

  __mtls_cleanup_root="${CERTS_DIR%/}/mtls"
  if [ -e "$__mtls_cleanup_root" ] || [ -L "$__mtls_cleanup_root" ]; then
    _mtls_validate_owned_dir "$__out" "$owner_domain" "$path_in" || return 1
    return 0
  fi

  if [[ "$owner_domain" =~ [[:cntrl:]] ]]; then
    echo "[Error] mTLS owner domain contains control characters." >&2
    return 1
  fi
  _mtls_normalize_valid_domain __mtls_cleanup_domain "$owner_domain" || return 1
  if [ -z "$path_in" ]; then
    echo "[Error] mTLS directory path required for ${__mtls_cleanup_domain}." >&2
    return 1
  fi
  if [[ "$path_in" =~ [[:cntrl:]] ]]; then
    echo "[Error] mTLS directory path for '${__mtls_cleanup_domain}' contains control characters." >&2
    return 1
  fi

  guard_mtls_root_dir || return 1
  if ! declare -F _runtime_path_resolve_allow_missing >/dev/null 2>&1; then
    echo "[Error] Missing runtime path resolver for mTLS cleanup validation." >&2
    return 1
  fi

  __mtls_cleanup_expected="${__mtls_cleanup_root}/${__mtls_cleanup_domain}"
  if [ "$path_in" != "$__mtls_cleanup_expected" ]; then
    echo "[Error] Missing mTLS material for '${__mtls_cleanup_domain}' may only be cleaned from its canonical path '${__mtls_cleanup_expected}', got '${path_in}'." >&2
    return 1
  fi

  __mtls_cleanup_root_cmp="$(_runtime_path_resolve_allow_missing "$__mtls_cleanup_root" && printf '.')" || {
    echo "[Error] Unable to resolve missing mTLS root directory '${__mtls_cleanup_root}'." >&2
    return 1
  }
  __mtls_cleanup_root_cmp="${__mtls_cleanup_root_cmp%.}"
  __mtls_cleanup_expected_cmp="$(_runtime_path_resolve_allow_missing "$__mtls_cleanup_expected" && printf '.')" || {
    echo "[Error] Unable to resolve canonical mTLS cleanup path '${__mtls_cleanup_expected}'." >&2
    return 1
  }
  __mtls_cleanup_expected_cmp="${__mtls_cleanup_expected_cmp%.}"
  __mtls_cleanup_path_cmp="$(_runtime_path_resolve_allow_missing "$path_in" && printf '.')" || {
    echo "[Error] Unable to resolve persisted mTLS cleanup path for '${__mtls_cleanup_domain}'." >&2
    return 1
  }
  __mtls_cleanup_path_cmp="${__mtls_cleanup_path_cmp%.}"
  if [ "$__mtls_cleanup_expected_cmp" != "${__mtls_cleanup_root_cmp%/}/${__mtls_cleanup_domain}" ] ||
    [ "$__mtls_cleanup_path_cmp" != "$__mtls_cleanup_expected_cmp" ]; then
    echo "[Error] Refusing noncanonical missing mTLS cleanup path for '${__mtls_cleanup_domain}'." >&2
    return 1
  fi

  if [ -e "$__mtls_cleanup_root" ] || [ -L "$__mtls_cleanup_root" ]; then
    _mtls_validate_owned_dir "$__out" "$owner_domain" "$path_in" || return 1
    return 0
  fi

  printf -v "$__out" '%s' "$__mtls_cleanup_expected_cmp"
}

function _mtls_get_explicit_owned_dir_with_mode() {
  local __out="${1:-}" owner_domain="${2:-}" validation_mode="${3:-render}"
  local __mtls_explicit_owner="" __mtls_explicit_raw="" __mtls_explicit_validated=""
  require_valid_var_name "$__out" || return 1
  _mtls_normalize_valid_domain __mtls_explicit_owner "$owner_domain" || return 1

  if [ -f "${BACKEND_MTLS_FILE:-}" ]; then
    if ! __mtls_explicit_raw="$(state_csv_get_two_col_value "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$__mtls_explicit_owner" "")"; then
      return 1
    fi
  fi
  if [ -z "$__mtls_explicit_raw" ]; then
    printf -v "$__out" '%s' ""
    return 0
  fi

  case "$validation_mode" in
  render)
    _mtls_validate_owned_dir __mtls_explicit_validated "$__mtls_explicit_owner" "$__mtls_explicit_raw" || return 1
    ;;
  cleanup)
    _mtls_validate_owned_dir_for_cleanup __mtls_explicit_validated "$__mtls_explicit_owner" "$__mtls_explicit_raw" || return 1
    ;;
  *)
    echo "[Error] Invalid internal mTLS validation mode: ${validation_mode}" >&2
    return 1
    ;;
  esac
  printf -v "$__out" '%s' "$__mtls_explicit_validated"
}

function _mtls_get_explicit_owned_dir() {
  _mtls_get_explicit_owned_dir_with_mode "${1:-}" "${2:-}" render
}

function _mtls_get_explicit_owned_dir_for_cleanup() {
  _mtls_get_explicit_owned_dir_with_mode "${1:-}" "${2:-}" cleanup
}

function _mtls_resolve_effective_mapping() {
  local __dir_out="${1:-}" __owner_out="${2:-}" requested_domain="${3:-}"
  local __mtls_effective_requested="" __mtls_effective_owner="" __mtls_effective_dir=""
  local __mtls_effective_target="" __mtls_effective_inherit="yes"
  require_valid_var_name "$__dir_out" || return 1
  require_valid_var_name "$__owner_out" || return 1
  if [ "$__dir_out" = "$__owner_out" ]; then
    echo "[Error] mTLS mapping output variables must be distinct." >&2
    return 1
  fi
  _mtls_normalize_valid_domain __mtls_effective_requested "$requested_domain" || return 1

  _mtls_get_explicit_owned_dir __mtls_effective_dir "$__mtls_effective_requested" || return 1
  if [ -n "$__mtls_effective_dir" ]; then
    __mtls_effective_owner="$__mtls_effective_requested"
  else
    __mtls_effective_target="$(backend_for_dedicated_host "$__mtls_effective_requested")"
    if [ -n "$__mtls_effective_target" ]; then
      _mtls_normalize_valid_domain __mtls_effective_target "$__mtls_effective_target" || return 1
      __mtls_effective_inherit="$(get_dedicated_host_inheritance "$__mtls_effective_requested" mtls)" || return 1
      if [ "$__mtls_effective_inherit" = "yes" ]; then
        _mtls_get_explicit_owned_dir __mtls_effective_dir "$__mtls_effective_target" || return 1
        if [ -n "$__mtls_effective_dir" ]; then
          __mtls_effective_owner="$__mtls_effective_target"
        fi
      fi
    fi
  fi

  printf -v "$__dir_out" '%s' "$__mtls_effective_dir"
  printf -v "$__owner_out" '%s' "$__mtls_effective_owner"
}

function _mtls_validate_backend_mtls_state() {
  local validation_mode="${1:-render}"
  local line="" line_no=0 owner_domain="" normalized_owner="" raw_dir="" validated_dir=""
  [ -f "${BACKEND_MTLS_FILE:-}" ] || return 0
  csv_require_header "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid backend mTLS state at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_MTLS_COLS" ]; then
      echo "[Error] Invalid backend mTLS state at line ${line_no}: expected ${STATE_BACKEND_MTLS_COLS} columns, got ${CSV_FIELD_COUNT}." >&2
      return 1
    fi
    owner_domain="${CSV_FIELDS[0]}"
    raw_dir="${CSV_FIELDS[1]}"
    if [[ "$owner_domain" =~ [[:cntrl:]] ]]; then
      echo "[Error] Invalid backend mTLS owner domain at line ${line_no}: control characters are not allowed." >&2
      return 1
    fi
    if ! _mtls_normalize_valid_domain normalized_owner "$owner_domain"; then
      echo "[Error] Invalid backend mTLS owner domain at line ${line_no}." >&2
      return 1
    fi
    if [ "$owner_domain" != "$normalized_owner" ]; then
      echo "[Error] Invalid backend mTLS owner mapping at line ${line_no}: owner key '${owner_domain}' must be canonical '${normalized_owner}'." >&2
      return 1
    fi
    case "$validation_mode" in
    render)
      _mtls_validate_owned_dir validated_dir "$normalized_owner" "$raw_dir" || {
        echo "[Error] Invalid backend mTLS owner mapping at line ${line_no}." >&2
        return 1
      }
      ;;
    cleanup)
      _mtls_validate_owned_dir_for_cleanup validated_dir "$normalized_owner" "$raw_dir" || {
        echo "[Error] Invalid backend mTLS owner mapping at line ${line_no}." >&2
        return 1
      }
      ;;
    *)
      echo "[Error] Invalid internal mTLS validation mode: ${validation_mode}" >&2
      return 1
      ;;
    esac
  done <"$BACKEND_MTLS_FILE"
}

function validate_backend_mtls_state_for_render() {
  _mtls_validate_backend_mtls_state render
}

function validate_backend_mtls_state_for_cleanup() {
  _mtls_validate_backend_mtls_state cleanup
}

function _resolve_backend_mtls_dir() {
  local __out="${1:-}" domain="${2:-}" normalized_domain="" mapping_owner=""
  local resolved_mtls_dir="" rechecked_mtls_dir=""
  require_valid_var_name "$__out" || return 1
  _mtls_normalize_valid_domain normalized_domain "$domain" || return 1

  validate_backend_mtls_state_for_render || return 1
  _mtls_resolve_effective_mapping resolved_mtls_dir mapping_owner "$normalized_domain" || return 1
  if [ -z "$resolved_mtls_dir" ]; then
    echo "[Error] mTLS not enabled for $normalized_domain" >&2
    return 1
  fi
  _mtls_validate_owned_dir rechecked_mtls_dir "$mapping_owner" "$resolved_mtls_dir" || return 1
  if [ "$rechecked_mtls_dir" != "$resolved_mtls_dir" ]; then
    echo "[Error] Refusing changed mTLS backend directory for '${mapping_owner}'." >&2
    return 1
  fi

  printf -v "$__out" '%s' "$rechecked_mtls_dir"
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
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    _domain_mtls_resolve "$__out" "$__mtls_orig_path_in"
    return $?
  fi
  if [ -z "$__mtls_orig_path_in" ]; then
    echo "[Error] mTLS directory path required." >&2
    return 1
  fi

  __mtls_orig_root="${CERTS_DIR%/}/mtls"
  guard_mtls_root_dir || return 1
  __mtls_orig_root_real="$(_realpath_portable "$__mtls_orig_root" && printf '.')" || {
    echo "[Error] Unable to resolve mTLS root directory '${__mtls_orig_root}'." >&2
    return 1
  }
  __mtls_orig_root_real="${__mtls_orig_root_real%.}"
  __mtls_orig_normalized="$(_normalize_delete_target_path "$__mtls_orig_path_in" && printf '.')" || {
    echo "[Error] Unable to resolve mTLS directory '${__mtls_orig_path_in}'." >&2
    return 1
  }
  __mtls_orig_normalized="${__mtls_orig_normalized%.}"

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
  actual="$(pwd -P && printf '.')" || return 1
  actual="${actual%$'\n.'}"
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
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    _domain_mtls_resolve original_mtls_dir "$mtls_dir" || return 1
    safe_rm_rf "$original_mtls_dir" "${original_mtls_dir%/*}"
    return $?
  fi
  _mtls_original_dir_path original_mtls_dir "$mtls_dir" || return 1
  _mtls_reject_original_dir_symlink "$original_mtls_dir" || return 1
  mtls_root="${CERTS_DIR%/}/mtls"
  guard_mtls_root_dir || return 1
  mtls_root_real="$(_realpath_portable "$mtls_root" && printf '.')" || {
    echo "[Error] Unable to resolve mTLS root directory '${mtls_root}'." >&2
    return 1
  }
  mtls_root_real="${mtls_root_real%.}"
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
  local mtls_dir="${1:-}" domain="${2:-}" mode="${3:-fresh}"
  _mtls_authority_generation_allowed "$mtls_dir" "$mode" || {
    _mtls_state_error "Refusing to overwrite retained authority material for $domain."; return 1;
  }
  _mtls_prepare_dir_for_mutation mtls_dir "$mtls_dir" || return 1
  (
    _mtls_cd_guarded_dir "$mtls_dir" || exit 1
    # Recheck from the pinned directory after preparation; a late material or
    # path change must not turn fresh generation into an accidental overwrite.
    _mtls_authority_generation_allowed "$mtls_dir" "$mode" || {
      _mtls_state_error "Refusing to overwrite retained authority material for $domain."; exit 1;
    }
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
