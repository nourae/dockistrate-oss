# shellcheck shell=bash

PERMISSIONS_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F __dockistrate_permissions_stat_loaded >/dev/null 2>&1; then
  # shellcheck source=./stat_helpers.sh
  source "${PERMISSIONS_COMMON_DIR}/stat_helpers.sh"
fi
if ! declare -F __dockistrate_runtime_paths_loaded >/dev/null 2>&1 && [ -f "${PERMISSIONS_COMMON_DIR}/../runtime_paths.sh" ]; then
  # Support direct sourcing of this helper without requiring lib/config.sh first.
  # shellcheck source=../runtime_paths.sh
  source "${PERMISSIONS_COMMON_DIR}/../runtime_paths.sh"
fi


function _ensure_tls_permissions() {
  local file="$1" target_mode="640" status=0
  if _is_sensitive_tls_file "$file"; then
    target_mode="600"
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
  fi
  _tighten_file_permissions "$file" "$target_mode"
}


function _print_sudo_hint() {
  local dir="$1" user group
  user="$(id -un 2>/dev/null || echo "$USER")"
  group="$(id -gn 2>/dev/null || echo "$USER")"
  echo "[Hint] Some files are not owned by ${user}:${group}. If needed, run:" >&2
  echo "       sudo chown -R ${user}:${group} \"${dir}\"" >&2
}


function _portable_stat_mode() {
  local file="$1" mode="" max_digits=4
  _permissions_stat_read '%a' '%p' "$file" || return 1
  mode="$PERMISSIONS_STAT_RECORD"
  if [ "$PERMISSIONS_STAT_DIALECT" = bsd ]; then
    # BSD %Lp omits special permission bits. Read the complete mode, including
    # file type, so verification cannot overlook set-ID or sticky bits.
    max_digits=7
  fi
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  [ "${#mode}" -le "$max_digits" ] && [ "$((8#$mode))" -le 65535 ] || return 1
  printf '%o' "$((8#$mode & 07777))"
}


function _private_file_is_regular_and_unlinked() {
  local file="${1:-}" links=""
  [ -n "$file" ] && [ ! -L "$file" ] && [ -f "$file" ] || return 1
  # This call normally runs in the permission operation's surviving shell,
  # allowing subsequent mode-reading substitutions to inherit its syntax choice.
  _permissions_stat_read '%h' '%l' "$file" || return 1
  links="$PERMISSIONS_STAT_RECORD"
  [ "$links" = "1" ]
}


# Operator history and log copies may contain credentials even when a later
# command selects redacted visibility. Refuse to use an unsafe existing file;
# callers create missing files under umask 077 before invoking this helper.
function _ensure_private_file_permissions() {
  local file="${1:-}" mode=""
  if ! runtime_state_path_guard_if_declared "$file" "private operator file" ||
    ! _private_file_is_regular_and_unlinked "$file"; then
    echo "[Error] Refusing unsafe private operator file." >&2
    return 1
  fi
  if ! chmod 600 "$file" 2>/dev/null; then
    echo "[Error] Unable to protect private operator file." >&2
    return 1
  fi
  if ! runtime_state_path_guard_if_declared "$file" "private operator file" ||
    ! _private_file_is_regular_and_unlinked "$file" ||
    ! mode="$(_portable_stat_mode "$file")" || [ "$mode" != "600" ]; then
    echo "[Error] Unable to verify private operator file permissions." >&2
    return 1
  fi
}


function _ensure_private_file_permissions_if_exists() {
  local file="${1:-}"
  [ -n "$file" ] || return 0
  runtime_state_path_guard_if_declared "$file" "private operator file" || return 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    _ensure_private_file_permissions "$file" || return 1
  fi
}


function _collect_private_runtime_file_paths() {
  # Callers declare this array locally; Bash's dynamic scope keeps independent
  # permission operations from sharing or caching configured paths.
  PRIVATE_RUNTIME_FILE_PATHS=("${INTERACTIVE_RECENT_FILE:-}" "${INTERACTIVE_FAVORITES_FILE:-}" \
    "${LOG_FILE:-}" "${AUDIT_LOG_FILE:-}" "${BACKEND_DOCKER_OPTS_FILE:-}" \
    "${CAPTURE_TLS_STATE_FILE:-}")
  if [ -n "${CONFIG_DIR:-}" ]; then
    PRIVATE_RUNTIME_FILE_PATHS+=("${CONFIG_DIR}/interactive_recent.csv" "${CONFIG_DIR}/interactive_favorites.csv" "${CONFIG_DIR}/backend_identity.csv")
  fi
  if [ -n "${LOG_DIR:-}" ]; then
    PRIVATE_RUNTIME_FILE_PATHS+=("${LOG_DIR}/docker_manager.log" "${LOG_DIR}/audit.log" "${LOG_DIR}/audit.log.1")
  fi
  if [ -n "${AUDIT_LOG_FILE:-}" ]; then
    PRIVATE_RUNTIME_FILE_PATHS+=("${AUDIT_LOG_FILE}.1")
  fi
}


function _is_private_runtime_file() {
  local file="${1:-}" candidate=""
  if [ -n "${STATE_DIR:-}" ]; then
    case "$file" in
    "${STATE_DIR%/}/domains/"*/config/* | "${STATE_DIR%/}/domains/"*/runtime/* | "${STATE_DIR%/}/domains/"*/certs/*/certificate.csv | "${STATE_DIR%/}/runtime/transactions/"*) return 0 ;;
    esac
  fi
  local -a PRIVATE_RUNTIME_FILE_PATHS=()
  [ -n "$file" ] || return 1
  case "$file" in /*) ;; *) file="${PWD}/${file}" ;; esac
  _collect_private_runtime_file_paths
  for candidate in "${PRIVATE_RUNTIME_FILE_PATHS[@]-}"; do
    [ -n "$candidate" ] || continue
    case "$candidate" in /*) ;; *) candidate="${PWD}/${candidate}" ;; esac
    if [ "$file" = "$candidate" ] || [ "$file" -ef "$candidate" ]; then
      return 0
    fi
  done
  return 1
}


function _is_sensitive_tls_file() {
  local file="$1" status=0
  # Filename recognition is independent of the configured live certificate
  # root: operators also repair extracted backups and alternate TLS trees.
  case "${file##*/}" in
  *.[Kk][Ee][Yy] | *[Kk][Ee][Yy].[Pp][Ee][Mm] | *[Pp][Rr][Ii][Vv][Kk][Ee][Yy]*.[Pp][Ee][Mm] | *.[Pp]12 | *.[Pp][Ff][Xx])
    return 0
    ;;
  *.[Pp][Ee][Mm])
    # Read the complete PEM so an I/O error cannot be hidden by an early match.
    # Never print key material. Status 2 distinguishes unreadable from public.
    if LC_ALL=C grep -E '^-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----[[:space:]]*$' "$file" >/dev/null; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] && return 1
      echo "[Error] Unable to inspect PEM permissions safely: $file" >&2
      return 2
    fi
    ;;
  esac
  return 1
}


function _permissions_intersect_mode() {
  local current="${1:-}" ceiling="${2:-}"
  case "$current" in '' | *[!0-7]*) return 1 ;; esac
  case "$ceiling" in '' | *[!0-7]*) return 1 ;; esac
  [ "${#current}" -le 4 ] && [ "${#ceiling}" -le 4 ] || return 1
  printf '%o' "$((8#$current & 8#$ceiling))"
}


# Inspect saved settings without changing their contents or permissions. The
# metadata helper also rejects hard links and checks GNU/BSD stat output.
function _global_settings_file_metadata() {
  local file="${1:-}"
  local PERMISSIONS_STAT_DEVICE="" PERMISSIONS_STAT_INODE="" PERMISSIONS_STAT_UID=""
  local PERMISSIONS_STAT_GID="" PERMISSIONS_STAT_MODE="" PERMISSIONS_STAT_LINKS=""
  local PERMISSIONS_STAT_TYPE="" PERMISSIONS_NORMALIZED_MODE=""
  _runtime_path_reject_symlink_prefix_components "$file" "global settings file" &&
    runtime_state_path_guard_if_declared "$file" "global settings file" || return 1
  if ! declare -F _permissions_metadata_stat >/dev/null 2>&1; then
    # shellcheck source=./metadata_transaction.sh
    source "${PERMISSIONS_COMMON_DIR}/metadata_transaction.sh" || return 1
  fi
  if ! _permissions_metadata_stat "$file" || [ "$PERMISSIONS_STAT_TYPE" != file ]; then
    echo '[Error] Refusing unsafe or unreadable global settings file.' >&2
    return 1
  fi
  printf '%s %s %s %s %s %s\n' "$PERMISSIONS_STAT_DEVICE" "$PERMISSIONS_STAT_INODE" \
    "$PERMISSIONS_STAT_UID" "$PERMISSIONS_STAT_GID" "$PERMISSIONS_STAT_MODE" "$PERMISSIONS_STAT_LINKS"
}


function _global_settings_file_snapshot() {
  local file="${1:-}"
  _runtime_path_reject_symlink_prefix_components "$file" "global settings file" &&
    runtime_state_path_guard_if_declared "$file" "global settings file" || return 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    _global_settings_file_metadata "$file"
  else
    printf '%s\n' missing
  fi
}


function _ensure_global_settings_file_permissions_if_exists() {
  local file="${1:-}" before="" after="" wanted=""
  local device="" inode="" owner="" group="" mode="" links=""
  [ -n "$file" ] || return 0
  before="$(_global_settings_file_snapshot "$file" || exit 1)" || return 1
  [ "$before" != missing ] || return 0
  IFS=' ' read -r device inode owner group mode links <<<"$before"
  wanted="$(_permissions_intersect_mode "$mode" 640 || exit 1)" || return 1
  _tighten_file_permissions "$file" 640 || return 1
  after="$(_global_settings_file_metadata "$file" || exit 1)" || return 1
  if [ "$after" != "$device $inode $owner $group $wanted $links" ]; then
    echo '[Error] Global settings identity or permissions changed during protection.' >&2
    return 1
  fi
}


function _tighten_file_permissions() {
  local file="$1" target_mode="${2:-640}" mode="" wanted="" actual=""
  if ! _private_file_is_regular_and_unlinked "$file" ||
    ! mode="$(_portable_stat_mode "$file")" ||
    ! wanted="$(_permissions_intersect_mode "$mode" "$target_mode")"; then
    echo "[Error] Unable to inspect file permissions safely: $file" >&2
    return 1
  fi
  if [ "$mode" != "$wanted" ] && ! chmod "$wanted" "$file" 2>/dev/null; then
    echo "[Error] Unable to tighten file permissions: $file" >&2
    return 1
  fi
  if ! _private_file_is_regular_and_unlinked "$file" ||
    ! actual="$(_portable_stat_mode "$file")" || [ "$actual" != "$wanted" ]; then
    echo "[Error] Unable to verify file permissions: $file" >&2
    return 1
  fi
}


function _ensure_runtime_dir_mode() {
  local dir_path="${1:-}" mode="${2:-}"
  [ -n "$dir_path" ] || return 0
  [ -n "$mode" ] || return 0

  local old_umask
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$dir_path" "runtime directory" || return 1
  fi
  old_umask="$(umask)"
  umask 077
  mkdir -p "$dir_path" 2>/dev/null || true
  umask "$old_umask"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$dir_path" "runtime directory" || return 1
  fi
  chmod "$mode" "$dir_path" 2>/dev/null || true
}


function _ensure_runtime_file_mode_if_exists() {
  local file_path="${1:-}" mode="${2:-}"
  [ -n "$file_path" ] || return 0
  [ -n "$mode" ] || return 0
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$file_path" "runtime file" || return 1
  fi
  [ -f "$file_path" ] || return 0
  chmod "$mode" "$file_path" 2>/dev/null || true
}


function _runtime_nginx_config_dir_mode() {
  local mode="750"
  if declare -F _nginx_image_runs_as_root >/dev/null 2>&1; then
    if ! _nginx_image_runs_as_root; then
      mode="755"
    fi
  fi
  printf '%s' "$mode"
}


function ensure_runtime_state_permissions() {
  local nginx_config_dir_mode mtls_root=""
  local private_file=""
  local -a PRIVATE_RUNTIME_FILE_PATHS=()
  nginx_config_dir_mode="$(_runtime_nginx_config_dir_mode)"
  if [ -n "${CERTS_DIR:-}" ]; then
    mtls_root="${CERTS_DIR%/}/mtls"
  fi

  if declare -F runtime_state_paths_guard >/dev/null 2>&1; then
    runtime_state_paths_guard \
      "${STATE_DIR:-}" \
      "${CONFIG_DIR:-}" \
      "${LOG_DIR:-}" \
      "${ERROR_LOG_DIR:-}" \
      "${TMP_DIR:-}" \
      "${CAPTURE_DIR:-}" \
      "${BACKUP_DIR:-}" \
      "${ACME_WEBROOT_DIR:-}" \
      "${CERTS_DIR:-}" \
      "${mtls_root:-}" \
      "${NGINX_CONFIG_DIR:-}" \
      "${NGINX_HTTP_CONF_DIR:-}" \
      "${NGINX_STREAM_CONF_DIR:-}" || return 1
  fi

  _ensure_runtime_dir_mode "${STATE_DIR:-}" 750
  _ensure_runtime_dir_mode "${CONFIG_DIR:-}" 750
  _ensure_runtime_dir_mode "${LOG_DIR:-}" 750
  _ensure_runtime_dir_mode "${ERROR_LOG_DIR:-}" 750
  _ensure_runtime_dir_mode "${TMP_DIR:-}" 700
  _ensure_runtime_dir_mode "${CAPTURE_DIR:-}" 700
  _ensure_runtime_dir_mode "${BACKUP_DIR:-}" 700
  _ensure_runtime_dir_mode "${ACME_WEBROOT_DIR:-}" 750
  _ensure_runtime_dir_mode "${CERTS_DIR:-}" 750

  if [ -n "${NGINX_CONFIG_DIR:-}" ] && [ -d "$NGINX_CONFIG_DIR" ]; then
    runtime_state_path_guard_if_declared "$NGINX_CONFIG_DIR" "nginx config directory" || return 1
    chmod "$nginx_config_dir_mode" "$NGINX_CONFIG_DIR" 2>/dev/null || true
  fi
  if [ -n "${NGINX_HTTP_CONF_DIR:-}" ] && [ -d "$NGINX_HTTP_CONF_DIR" ]; then
    runtime_state_path_guard_if_declared "$NGINX_HTTP_CONF_DIR" "nginx http config directory" || return 1
    chmod "$nginx_config_dir_mode" "$NGINX_HTTP_CONF_DIR" 2>/dev/null || true
  fi
  if [ -n "${NGINX_STREAM_CONF_DIR:-}" ] && [ -d "$NGINX_STREAM_CONF_DIR" ]; then
    runtime_state_path_guard_if_declared "$NGINX_STREAM_CONF_DIR" "nginx stream config directory" || return 1
    chmod "$nginx_config_dir_mode" "$NGINX_STREAM_CONF_DIR" 2>/dev/null || true
  fi

  _ensure_global_settings_file_permissions_if_exists "${GLOBAL_SETTINGS_FILE:-}" || return 1
  _ensure_runtime_file_mode_if_exists "${CONFIG_DIR:-}/state_schema_version" 640
  _collect_private_runtime_file_paths
  # Deduplicate only this write pass, not the collector used for every entry
  # during permission repair. Preserve first-seen literal paths and recheck
  # all unique paths on every operation; never cache permissions or identity.
  local existing="" duplicate=false
  local -a unique_private_paths=()
  for private_file in "${PRIVATE_RUNTIME_FILE_PATHS[@]-}"; do
    [ -n "$private_file" ] || continue
    duplicate=false
    for existing in "${unique_private_paths[@]-}"; do
      if [ "$private_file" = "$existing" ]; then duplicate=true; break; fi
    done
    [ "$duplicate" = false ] || continue
    unique_private_paths+=("$private_file")
    _ensure_private_file_permissions_if_exists "$private_file" || return 1
  done

  if [ -n "${BACKUP_DIR:-}" ] && [ -d "${BACKUP_DIR}" ]; then
    find "${BACKUP_DIR}" -maxdepth 1 -type f -name '*.tar.gz' -exec chmod 600 {} + 2>/dev/null || true
  fi

  if [ -n "${CAPTURE_DIR:-}" ] && [ -d "${CAPTURE_DIR}" ]; then
    find "${CAPTURE_DIR}" -maxdepth 1 -type f -name '*.pcap' -exec chmod 600 {} + 2>/dev/null || true
  fi
  _ensure_domain_layout_permissions
}

function _ensure_domain_layout_permissions() {
  local state_root="${STATE_DIR:-}" domains="" domain_dir="" subtree="" path=""
  [ -n "$state_root" ] || return 0
  domains="${state_root%/}/domains"
  if [ -d "$domains" ]; then
    runtime_state_path_guard_if_declared "$domains" "domain permission root" || return 1
    _ensure_runtime_dir_mode "$domains" 750 || return 1
    for domain_dir in "$domains"/*; do
      [ -d "$domain_dir" ] || continue
      runtime_state_path_guard_if_declared "$domain_dir" "domain permission directory" || return 1
      _ensure_runtime_dir_mode "$domain_dir" 750 || return 1
      for subtree in "$domain_dir/config" "$domain_dir/runtime" "$domain_dir/certs" "$domain_dir/mtls"; do
        [ -d "$subtree" ] || continue
        runtime_state_path_guard_if_declared "$subtree" "domain private directory" || return 1
        while IFS= read -r -d '' path; do
          runtime_state_path_guard_if_declared "$path" "domain permission entry" || return 1
          if [ -d "$path" ]; then
            case "$path" in "$domain_dir/runtime" | "$domain_dir/runtime"/*) _ensure_runtime_dir_mode "$path" 700 || return 1 ;;
            *) _ensure_runtime_dir_mode "$path" 750 || return 1 ;; esac
          else
            case "$path" in
            "$domain_dir/config"/* | "$domain_dir/runtime"/* | */certificate.csv) _tighten_file_permissions "$path" 600 || return 1 ;;
            *) _ensure_tls_permissions "$path" || return 1 ;;
            esac
          fi
        done < <(find "$subtree" \( -type d -o -type f \) -print0)
      done
    done
  fi
  for subtree in "${state_root%/}/shared/acme" "${state_root%/}/shared/certificate_receipts" "${state_root%/}/runtime/transactions"; do
    [ -d "$subtree" ] || continue
    runtime_state_path_guard_if_declared "$subtree" "private certificate/runtime root" || return 1
    while IFS= read -r -d '' path; do
      # Certbot's live links are intentionally ignored; archive material owns
      # the bytes and is protected directly without following a symlink.
      runtime_state_path_guard_if_declared "$path" "private certificate/runtime entry" || return 1
      if [ -d "$path" ]; then
        _ensure_runtime_dir_mode "$path" 700 || return 1
      else
        _tighten_file_permissions "$path" 600 || return 1
      fi
    done < <(find "$subtree" \( -type d -o -type f \) -print0)
  done
}


# Dedicated load sentinel for entrypoints that source this helper directly.
function __dockistrate_permissions_common_loaded() {
  :
}
