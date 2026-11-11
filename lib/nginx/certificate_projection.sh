# shellcheck shell=bash

# Runtime factory/update modules can load this operation directly. Dependency
# files contain declarations only, so the normal alphabetical loader remains
# deterministic and direct loading does not inspect or change runtime state.
_NGINX_CERTIFICATE_PROJECTION_SOURCE="${BASH_SOURCE[0]}"
case "$_NGINX_CERTIFICATE_PROJECTION_SOURCE" in
/*) ;;
*) _NGINX_CERTIFICATE_PROJECTION_SOURCE="$PWD/$_NGINX_CERTIFICATE_PROJECTION_SOURCE" ;;
esac
if ! declare -F _realpath_portable >/dev/null 2>&1; then
  # shellcheck source=lib/utils/fs.sh
  source "${_NGINX_CERTIFICATE_PROJECTION_SOURCE%/*}/../utils/fs.sh"
fi
if ! declare -F require_valid_var_name >/dev/null 2>&1; then
  # shellcheck source=lib/utils/validators.sh
  source "${_NGINX_CERTIFICATE_PROJECTION_SOURCE%/*}/../utils/validators.sh"
fi
if ! declare -F _secure_fs_require_capabilities >/dev/null 2>&1; then
  # shellcheck source=lib/utils/secure_fs.sh
  source "${BASH_SOURCE[0]%/*}/../utils/secure_fs.sh"
fi
# shellcheck source=lib/nginx/certificate_projection_format.sh
source "${BASH_SOURCE[0]%/*}/certificate_projection_format.sh"
# shellcheck source=lib/nginx/certificate_projection_store.sh
source "${BASH_SOURCE[0]%/*}/certificate_projection_store.sh"
# shellcheck source=lib/nginx/certificate_projection_build.sh
source "${BASH_SOURCE[0]%/*}/certificate_projection_build.sh"
# shellcheck source=lib/nginx/certificate_projection_recovery.sh
source "${BASH_SOURCE[0]%/*}/certificate_projection_recovery.sh"

function _nginx_certificate_projection_helper() {
  # Bash 3 cannot reliably start the descriptor supervisor while an inherited
  # signal handler is unwinding through EXIT. A fixed fresh entry keeps normal
  # operations and transaction recovery on the same literal-argument boundary.
  _secure_fs_run_fresh "$_NGINX_CERTIFICATE_PROJECTION_SOURCE" _nginx_certificate_projection_worker "$@"
}

function _nginx_certificate_projection_worker() {
  local operation="${1:-}" root="${2:-}" target="${3:-}" status=0 selected=""
  declare -F _secure_fs_with_file >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || return 1
  _secure_fs_require_capabilities || return 1
  case "$operation" in
  build) _projection_build "$root" "$target" "${4-legacy}" || status=$? ;;
  verify | prune) _projection_operate "$operation" "$root" "$target" || status=$? ;;
  capture) _projection_capture "$root" || status=$? ;;
  recover) _projection_recover "$root" || status=$? ;;
  mounted)
    selected="$(_projection_mount_source && printf '.')" || status=$?
    if [ "$status" -eq 0 ]; then [ "${selected%.}" = "$target" ] || status=1; fi
    ;;
  *) status=1 ;;
  esac
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    echo "[Error] Certificate projection: unsafe or inconsistent certificate snapshot." >&2
  fi
  return "$status"
}

function _nginx_certificate_projection_manifest() {
  local projection_cert_root="" projection_line="" projection_line_no=0
  local projection_cert_dir="" projection_relative="" projection_owner="" projection_mtls_dir=""
  local projection_source_root="$CERTS_DIR"
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    projection_source_root="${DOMAINS_DIR:-${STATE_DIR}/domains}"
  fi
  projection_cert_root="$(_realpath_portable "$projection_source_root" && printf '.')" || return 1
  projection_cert_root="${projection_cert_root%.}"
  if [ -f "${BACKEND_PORTS_FILE:-}" ]; then
    _validate_backend_ports_state_for_render || return 1
    while IFS= read -r projection_line || [ -n "$projection_line" ]; do
      projection_line_no=$((projection_line_no + 1))
      [ "$projection_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$projection_line" || return 1
      [ "${STATE_BP_RECORD_TYPE:-}" = port ] || continue
      [ "${STATE_BP_PROTOCOL:-}" = https ] || continue
      normalize_cert_dir projection_cert_dir "${STATE_BP_CERT_REF:-}" || return 1
      case "$projection_cert_dir" in
      "$projection_cert_root") projection_relative="" ;;
      "$projection_cert_root"/*) projection_relative="${projection_cert_dir#"$projection_cert_root"/}/" ;;
      *) return 1 ;;
      esac
      printf '%s\0' server-cert "${projection_cert_dir}/fullchain.pem" "${projection_relative}fullchain.pem"
      printf '%s\0' server-key "${projection_cert_dir}/privkey.pem" "${projection_relative}privkey.pem"
    done <"$BACKEND_PORTS_FILE"
  fi
  if [ -f "${BACKEND_MTLS_FILE:-}" ]; then
    validate_backend_mtls_state_for_render || return 1
    projection_line_no=0
    while IFS= read -r projection_line || [ -n "$projection_line" ]; do
      projection_line_no=$((projection_line_no + 1))
      [ "$projection_line_no" -eq 1 ] && continue
      csv_parse_line "$projection_line" || return 1
      projection_owner="${CSV_FIELDS[0]}"
      _mtls_validate_owned_dir projection_mtls_dir "$projection_owner" "${CSV_FIELDS[1]}" || return 1
      # CRLs are mandatory. Rendering normally creates a missing CRL first;
      # direct recreation must not accidentally project an incomplete trust set.
      [ -f "${projection_mtls_dir}/ca.crl" ] || _generate_backend_crl "$projection_mtls_dir" >&2 || return 1
      projection_relative="${projection_mtls_dir#"$projection_cert_root"/}"
      printf '%s\0' mtls-ca "${projection_mtls_dir}/ca.crt" "${projection_relative}/ca.crt"
      printf '%s\0' mtls-crl "${projection_mtls_dir}/ca.crl" "${projection_relative}/ca.crl"
    done <"$BACKEND_MTLS_FILE"
  fi
  # A failed producer must never turn its partial output into a valid snapshot.
  printf '%s\0' complete
}

function _nginx_prepare_certificate_projection() {
  local projection_out="${1:-}" projection_result="" projection_root="${CONFIG_DIR}/proxy_certs"
  local projection_source_root="$CERTS_DIR" projection_server_source_policy=legacy
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    projection_source_root="${DOMAINS_DIR:-${STATE_DIR}/domains}"
    projection_server_source_policy=regular
    runtime_state_path_guard_if_declared "$projection_source_root" "domain certificate source root" || return 1
    (umask 077; mkdir -p "$projection_source_root") || return 1
  fi
  require_valid_var_name "$projection_out" || return 1
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$CERTS_DIR" "$projection_root" || return 1
  fi
  if ! projection_result="$(_nginx_certificate_projection_manifest |
    _nginx_certificate_projection_helper build "$projection_source_root" "$projection_root" "$projection_server_source_policy" && printf '.')"; then
    return 1
  fi
  projection_result="${projection_result%.}"
  _nginx_verify_certificate_projection "$projection_result" || return 1
  printf -v "$projection_out" '%s' "$projection_result"
}

function _nginx_verify_certificate_projection() {
  _nginx_certificate_projection_helper verify "${CONFIG_DIR}/proxy_certs" "${1:-}"
}

function _nginx_prune_certificate_projections() {
  _nginx_certificate_projection_helper prune "${CONFIG_DIR}/proxy_certs" "${1:-}"
}

function _nginx_container_has_certificate_projection() {
  local projection_path="${1:-}" projection_mounts=""
  projection_mounts="$(docker inspect -f "$(_projection_mount_format)" "$NGINX_CONTAINER_NAME" 2>/dev/null)" || return 1
  printf '%s\n' "$projection_mounts" |
    _nginx_certificate_projection_helper mounted "${CONFIG_DIR}/proxy_certs" "$projection_path"
}

function _nginx_prepare_projection_transaction_rollback() {
  # Ordinary rendering and standalone backup/permission helpers must not
  # acquire a Docker dependency. Only a verified, currently mounted snapshot
  # covered by this content transaction needs protection from archive replay.
  [ "${SKIP_DOCKER_CHECKS:-}" != true ] || return 0
  [ -n "${CONFIG_DIR:-}" ] && [ -n "${NGINX_CONTAINER_NAME:-}" ] || return 0
  declare -F nginx_container_is_managed >/dev/null 2>&1 || return 0
  declare -F _nginx_prepare_runtime_rollback >/dev/null 2>&1 || return 0
  [ -d "${CONFIG_DIR}/proxy_certs" ] || return 0
  local projection_root="" projection_target="" projection_covered=false
  local projection_mounts="" projection_token="" projection_status=0
  projection_root="$(_realpath_portable "${CONFIG_DIR}/proxy_certs" && printf '.')" || return 1
  projection_root="${projection_root%.}"
  for projection_target in "${ROLLBACK_FILES[@]-}"; do
    [ -n "$projection_target" ] || continue
    case "$projection_root" in "$projection_target" | "$projection_target"/*) projection_covered=true ;; esac
    case "$projection_target" in "$projection_root"/*) projection_covered=true ;; esac
  done
  [ "$projection_covered" = true ] || return 0
  nginx_container_is_managed || return 0
  projection_mounts="$(docker inspect -f "$(_projection_mount_format)" "$NGINX_CONTAINER_NAME" 2>/dev/null)" || return 1
  if projection_token="$(printf '%s\n' "$projection_mounts" |
    _nginx_certificate_projection_helper capture "$projection_root" -)"; then
    :
  else
    projection_status=$?
    # A legacy mount or already damaged derived cache has no verified snapshot
    # to retain. The normal updater rebuilds those from authoritative sources.
    [ "$projection_status" -eq 3 ] && return 0
    echo "[Error] Cannot retain the active certificate snapshot for transaction rollback." >&2
    return 1
  fi
  _nginx_prepare_runtime_rollback "${NGINX_IMAGE:-}" || return 1
  NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE="$projection_token"
}

function _nginx_recover_certificate_projection() {
  local recovery_out="${1:-}" recovery_token="${2:-}" recovery_result=""
  require_valid_var_name "$recovery_out" || return 1
  recovery_result="$(printf '%s' "$recovery_token" |
    _nginx_certificate_projection_helper recover "${CONFIG_DIR}/proxy_certs" - && printf '.')" || return 1
  recovery_result="${recovery_result%.}"
  _nginx_verify_certificate_projection "$recovery_result" || return 1
  printf -v "$recovery_out" '%s' "$recovery_result"
}
