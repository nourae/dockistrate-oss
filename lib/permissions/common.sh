# shellcheck shell=bash

PERMISSIONS_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F __dockistrate_runtime_paths_loaded >/dev/null 2>&1 && [ -f "${PERMISSIONS_COMMON_DIR}/../runtime_paths.sh" ]; then
  # Support direct sourcing of this helper without requiring lib/config.sh first.
  # shellcheck source=../runtime_paths.sh
  source "${PERMISSIONS_COMMON_DIR}/../runtime_paths.sh"
fi


function _ensure_tls_permissions() {
  local file="$1"
  local target_mode="640"
  if _is_sensitive_tls_file "$file" "${CERTS_DIR:-}"; then
    target_mode="600"
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
  local file="$1" mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
  if [ -n "$mode" ]; then
    printf '%s' "$mode"
    return 0
  fi
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
  if [ -n "$mode" ]; then
    printf '%s' "$mode"
    return 0
  fi
  return 1
}


function _is_sensitive_tls_file() {
  local file="$1" certs_root="$2"
  if [ -n "$certs_root" ]; then
    case "$file" in
    "$certs_root"/*) ;;
    *) return 1 ;;
    esac
  fi

  case "$file" in
  *.key | *key.pem | *privkey.pem | *privkey*.pem | *.[Pp]12 | *.[Pp][Ff][Xx])
    return 0
    ;;
  esac
  return 1
}


function _tighten_file_permissions() {
  local file="$1" target_mode="${2:-640}" mode trimmed perm_owner perm_group perm_other
  [ -f "$file" ] || return 0
  if ! mode=$(_portable_stat_mode "$file"); then
    # Fall back to tightening without inspection if stat unavailable
    chmod "$target_mode" "$file" 2>/dev/null || chmod 600 "$file" 2>/dev/null || true
    return 0
  fi

  trimmed="$mode"
  while [ "${trimmed:0:1}" = "0" ] && [ "${#trimmed}" -gt 1 ]; do
    trimmed="${trimmed:1}"
  done
  trimmed=$(printf '%03d' "$trimmed")
  perm_owner="${trimmed:0:1}"
  perm_group="${trimmed:1:1}"
  perm_other="${trimmed:2:1}"

  if [ "$target_mode" = "600" ]; then
    if [ "$trimmed" != "600" ]; then
      chmod 600 "$file" 2>/dev/null || true
    fi
    return 0
  fi

  if ((perm_other != 0 || perm_group > 4 || perm_owner > 6)); then
    chmod "$target_mode" "$file" 2>/dev/null || chmod 600 "$file" 2>/dev/null || true
  elif ((perm_owner < 6)); then
    chmod "$target_mode" "$file" 2>/dev/null || chmod 600 "$file" 2>/dev/null || true
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

  _ensure_runtime_file_mode_if_exists "${GLOBAL_SETTINGS_FILE:-}" 640
  _ensure_runtime_file_mode_if_exists "${CONFIG_DIR:-}/state_schema_version" 640
  _ensure_runtime_file_mode_if_exists "${LOG_FILE:-}" 640
  _ensure_runtime_file_mode_if_exists "${AUDIT_LOG_FILE:-}" 640
  _ensure_runtime_file_mode_if_exists "${BACKEND_DOCKER_OPTS_FILE:-}" 600
  _ensure_runtime_file_mode_if_exists "${CAPTURE_TLS_STATE_FILE:-}" 600

  if [ -n "${BACKUP_DIR:-}" ] && [ -d "${BACKUP_DIR}" ]; then
    find "${BACKUP_DIR}" -maxdepth 1 -type f -name '*.tar.gz' -exec chmod 600 {} + 2>/dev/null || true
  fi

  if [ -n "${CAPTURE_DIR:-}" ] && [ -d "${CAPTURE_DIR}" ]; then
    find "${CAPTURE_DIR}" -maxdepth 1 -type f -name '*.pcap' -exec chmod 600 {} + 2>/dev/null || true
  fi
}


# Dedicated load sentinel for entrypoints that source this helper directly.
function __dockistrate_permissions_common_loaded() {
  :
}
