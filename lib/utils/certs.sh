# shellcheck shell=bash
function cert_ref_to_container_dir() {
  local __var="$1" cert_ref="${2:-}"
  require_valid_var_name "$__var" || return 1

  if [ -z "$cert_ref" ] || [ "$cert_ref" = "none" ]; then
    printf -v "$__var" '%s' ""
    return 0
  fi

  local certs_root="" normalized_ref=""
  if ! certs_root="$(_realpath_portable "$CERTS_DIR")"; then
    echo "[Error] Unable to resolve certificate root directory '${CERTS_DIR}'." >&2
    return 1
  fi
  if ! normalize_cert_dir normalized_ref "$cert_ref"; then
    return 1
  fi

  case "$normalized_ref" in
  "$certs_root")
    printf -v "$__var" '%s' "/etc/letsencrypt"
    return 0
    ;;
  "$certs_root"/*)
    printf -v "$__var" '%s' "/etc/letsencrypt${normalized_ref#${certs_root}}"
    return 0
    ;;
  esac

  echo "[Error] Certificate directory '${cert_ref}' must reside within '${CERTS_DIR}'." >&2
  return 1
}

function normalize_cert_dir() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  local __cert_path="$path_in"

  if [ -z "$__cert_path" ]; then
    printf -v "$__var" '%s' ""
    return 0
  fi

  if [[ "$__cert_path" == certs/* ]]; then
    __cert_path="${__cert_path#certs/}"
  fi
  if [[ "$__cert_path" != /* ]]; then
    __cert_path="$CERTS_DIR/$__cert_path"
  fi

  local __certs_root=""
  if ! __certs_root="$(_realpath_portable "$CERTS_DIR")"; then
    echo "[Error] Unable to resolve certificate root directory '${CERTS_DIR}'." >&2
    return 1
  fi

  local __resolved_cert_path=""
  if ! __resolved_cert_path="$(_realpath_portable "$__cert_path")"; then
    echo "[Error] Unable to resolve certificate directory '${path_in}'." >&2
    return 1
  fi

  case "$__resolved_cert_path" in
  "$__certs_root" | "$__certs_root"/*)
    printf -v "$__var" '%s' "$__resolved_cert_path"
    return 0
    ;;
  esac

  echo "[Error] Certificate directory '${path_in}' must reside within '${CERTS_DIR}'." >&2
  return 1
}

function guard_mtls_root_dir() {
  local mtls_root="${CERTS_DIR%/}/mtls"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$mtls_root" "mTLS root directory" || return 1
  fi
  if [ -L "$mtls_root" ]; then
    echo "[Error] Refusing to use symlinked mTLS root directory: ${mtls_root}" >&2
    return 1
  fi
}

function ensure_mtls_root_dir() {
  local mtls_root="${CERTS_DIR%/}/mtls" old_umask=""
  guard_mtls_root_dir || return 1
  old_umask="$(umask)"
  umask 077
  mkdir -p "$mtls_root" || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  guard_mtls_root_dir || return 1
  chmod 750 "$mtls_root" 2>/dev/null || true
}

# Normalize mTLS path under CERTS_DIR/mtls.
function normalize_mtls_dir() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1

  if [ -z "$path_in" ]; then
    printf -v "$__var" '%s' ""
    return 0
  fi

  local mtls_root="${CERTS_DIR%/}/mtls"
  local mtls_root_real=""
  guard_mtls_root_dir || return 1
  if ! mtls_root_real="$(_realpath_portable "$mtls_root")"; then
    echo "[Error] Unable to resolve mTLS root directory '${mtls_root}'." >&2
    return 1
  fi

  local normalized=""
  if ! normalized="$(_realpath_portable "$path_in")"; then
    if ! normalized="$(_normalize_delete_target_path "$path_in")"; then
      echo "[Error] Unable to resolve mTLS directory '${path_in}'." >&2
      return 1
    fi
  fi

  case "$normalized" in
  "$mtls_root_real" | "$mtls_root_real"/*)
    printf -v "$__var" '%s' "$normalized"
    return 0
    ;;
  esac

  echo "[Error] mTLS directory '${path_in}' must reside within '${mtls_root_real}'." >&2
  return 1
}

function relativize_cert_dir() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  local __relative_path="$path_in"

  if [ -z "$__relative_path" ]; then
    printf -v "$__var" '%s' ""
    return 0
  fi

  local __certs_root=""
  if __certs_root="$(_realpath_portable "$CERTS_DIR")"; then
    if [ "$__relative_path" = "$__certs_root" ]; then
      __relative_path=""
    elif [[ $__relative_path == "$__certs_root"/* ]]; then
      __relative_path="${__relative_path#${__certs_root}/}"
    fi
  else
    __certs_root="${CERTS_DIR%/}"
    if [ "$__relative_path" = "$__certs_root" ]; then
      __relative_path=""
    elif [[ $__relative_path == "$__certs_root"/* ]]; then
      __relative_path="${__relative_path#${__certs_root}/}"
    fi
  fi

  if [[ $__relative_path == certs/* ]]; then
    __relative_path="${__relative_path#certs/}"
  fi

  __relative_path="${__relative_path#./}"

  printf -v "$__var" '%s' "$__relative_path"
}


function canonicalize_cert_ref_rel() {
  local __var="$1" cert_ref="${2:-}" __normalized_cert_path="" __relative_cert_path=""
  require_valid_var_name "$__var" || return 1

  if [ -z "$cert_ref" ] || [ "$cert_ref" = "none" ]; then
    printf -v "$__var" '%s' ""
    return 0
  fi

  if normalize_cert_dir __normalized_cert_path "$cert_ref" 2>/dev/null; then
    relativize_cert_dir __relative_cert_path "$__normalized_cert_path"
    printf -v "$__var" '%s' "$__relative_cert_path"
    return 0
  fi

  __relative_cert_path="$cert_ref"
  if [[ "$__relative_cert_path" == certs/* ]]; then
    __relative_cert_path="${__relative_cert_path#certs/}"
  fi

  local __certs_root="${CERTS_DIR%/}/"
  if [[ "$__relative_cert_path" == "$__certs_root"* ]]; then
    __relative_cert_path="${__relative_cert_path#${__certs_root}}"
  fi

  __relative_cert_path="${__relative_cert_path#./}"
  printf -v "$__var" '%s' "$__relative_cert_path"
}

function letsencrypt_source_domain_from_cert_ref() {
  local __var="$1" cert_ref="${2:-}" source_cert_rel="" leaf=""
  require_valid_var_name "$__var" || return 1

  if ! canonicalize_cert_ref_rel source_cert_rel "$cert_ref"; then
    return 1
  fi

  case "$source_cert_rel" in
  letsencrypt/live/*)
    leaf="${source_cert_rel#letsencrypt/live/}"
    leaf="${leaf%%/*}"
    if [[ "$leaf" =~ ^(.+)_([0-9]+)$ ]]; then
      leaf="${BASH_REMATCH[1]}"
    fi
    printf -v "$__var" '%s' "$leaf"
    return 0
    ;;
  *)
    printf -v "$__var" '%s' ""
    return 0
    ;;
  esac
}

function letsencrypt_source_has_remaining_consumers() {
  local source_domain="${1:-}"
  shift || true

  [ -n "$source_domain" ] || return 1
  [ -f "$BACKEND_PORTS_FILE" ] || return 1

  local -a exclude_refs=()
  local exclude_ref="" candidate_rel="" candidate_source="" line="" line_no=0
  for exclude_ref in "$@"; do
    [ -n "$exclude_ref" ] || continue
    if canonicalize_cert_ref_rel candidate_rel "$exclude_ref"; then
      exclude_refs+=("$candidate_rel")
    fi
  done

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
    [ -n "${STATE_BP_CERT_REF:-}" ] || continue
    [ "${STATE_BP_CERT_REF:-}" != "none" ] || continue

    if ! canonicalize_cert_ref_rel candidate_rel "${STATE_BP_CERT_REF}"; then
      continue
    fi
    if ! letsencrypt_source_domain_from_cert_ref candidate_source "$candidate_rel"; then
      continue
    fi
    [ -n "$candidate_source" ] || continue
    [ "$candidate_source" = "$source_domain" ] || continue

    local excluded=false
    if [ ${#exclude_refs[@]} -gt 0 ]; then
      local existing_ref
      for existing_ref in "${exclude_refs[@]}"; do
        if [ "$existing_ref" = "$candidate_rel" ]; then
          excluded=true
          break
        fi
      done
    fi

    if [ "$excluded" != "true" ]; then
      return 0
    fi
  done <"$BACKEND_PORTS_FILE"

  return 1
}

function is_existing_cert_dir() {
  local p="${1:-}" abs=""
  if ! normalize_cert_dir abs "$p"; then
    return 1
  fi
  [ -d "$abs" ]
}
