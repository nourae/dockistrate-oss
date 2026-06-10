# shellcheck shell=bash
if ! declare -F __dockistrate_permissions_common_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/permissions.sh first.
  # shellcheck source=./common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

function _fix_permissions_is_darwin_host() {
  [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]
}

function _fix_permissions_is_numeric_id() {
  case "${1:-}" in
  '' | *[!0-9]*)
    return 1
    ;;
  *)
    return 0
    ;;
  esac
}

function _fix_permissions_reject_symlinked_certbot_path() {
  local certbot_path="${1:-}" path_label="${2:-path}"

  [ -n "$certbot_path" ] || return 1
  if [ -L "$certbot_path" ]; then
    echo "[Error] Refusing to prepare symlinked Darwin Certbot ${path_label}: '${certbot_path}'." >&2
    return 1
  fi
  return 0
}

function _fix_permissions_prepare_certbot_mount_tree() {
  local mount_root="${1:-}" certbot_uid="${2:-}" certbot_gid="${3:-}" mode_profile="${4:-plain}"
  local tls_file=""

  [ -n "$mount_root" ] || return 1
  [ -d "$mount_root" ] || return 1

  if ! find "$mount_root" \( -type d -o -type f \) -exec chown "${certbot_uid}:${certbot_gid}" {} + 2>/dev/null; then
    echo "[Error] Unable to change ownership under '${mount_root}'." >&2
    return 1
  fi
  if ! find "$mount_root" -type d -exec chmod 750 {} + 2>/dev/null; then
    echo "[Error] Unable to prepare writable directories under '${mount_root}'." >&2
    return 1
  fi

  if [ "$mode_profile" = "tls" ]; then
    while IFS= read -r tls_file; do
      [ -n "$tls_file" ] || continue
      if _is_sensitive_tls_file "$tls_file" "${CERTS_DIR:-}"; then
        if ! chmod 600 "$tls_file" 2>/dev/null; then
          echo "[Error] Unable to set mode 600 on TLS file '${tls_file}'." >&2
          return 1
        fi
      else
        if ! chmod 640 "$tls_file" 2>/dev/null; then
          echo "[Error] Unable to set mode 640 on TLS file '${tls_file}'." >&2
          return 1
        fi
      fi
    done < <(find "$mount_root" -type f -print 2>/dev/null)
  elif ! find "$mount_root" -type f -exec chmod 640 {} + 2>/dev/null; then
    echo "[Error] Unable to prepare writable files under '${mount_root}'." >&2
    return 1
  fi
}

function fix_permissions_certbot_darwin_user() {
  local current_uid="" certbot_uid="${SUDO_UID:-}" certbot_gid="${SUDO_GID:-}"
  local letsencrypt_root="" acme_root=""

  if ! _fix_permissions_is_darwin_host; then
    echo "[Error] fix-permissions --certbot-darwin-user is only supported on macOS/Darwin." >&2
    return 1
  fi

  current_uid="$(id -u 2>/dev/null || true)"
  if [ "$current_uid" != "0" ]; then
    echo "[Error] fix-permissions --certbot-darwin-user must be run with sudo." >&2
    return 1
  fi
  if ! _fix_permissions_is_numeric_id "$certbot_uid" || ! _fix_permissions_is_numeric_id "$certbot_gid"; then
    echo "[Error] fix-permissions --certbot-darwin-user requires numeric SUDO_UID and SUDO_GID." >&2
    return 1
  fi
  if [ -z "${CERTS_DIR:-}" ] || [ -z "${ACME_WEBROOT_DIR:-}" ]; then
    echo "[Error] Certificate and ACME webroot directories are not configured." >&2
    return 1
  fi

  letsencrypt_root="${CERTS_DIR%/}/letsencrypt"
  acme_root="${ACME_WEBROOT_DIR%/}"

  _fix_permissions_reject_symlinked_certbot_path "${CERTS_DIR%/}" "certificate root" || return 1
  _fix_permissions_reject_symlinked_certbot_path "$letsencrypt_root" "Let's Encrypt mount root" || return 1
  _fix_permissions_reject_symlinked_certbot_path "$acme_root" "ACME webroot" || return 1

  mkdir -p "$letsencrypt_root" "$acme_root" || return 1
  _fix_permissions_prepare_certbot_mount_tree "$letsencrypt_root" "$certbot_uid" "$certbot_gid" "tls" || return 1
  _fix_permissions_prepare_certbot_mount_tree "$acme_root" "$certbot_uid" "$certbot_gid" "plain" || return 1

  if declare -F _certbot_docker_mount_roots_writable_by_user >/dev/null 2>&1; then
    if ! _certbot_docker_mount_roots_writable_by_user "$certbot_uid" "$certbot_gid" "$letsencrypt_root" "$acme_root"; then
      echo "[Error] Darwin Certbot mounts are still not writable by ${certbot_uid}:${certbot_gid}." >&2
      return 1
    fi
  fi

  echo "[Info] Prepared Darwin Certbot mounts for ${certbot_uid}:${certbot_gid}: ${letsencrypt_root}, ${acme_root}"
}

function fix_permissions() {
  local dir="${1:-$BASE_DIR}"
  [ -d "$dir" ] || {
    echo "[Error] Directory not found: $dir" >&2
    return 1
  }

  dir="$(cd "$dir" && pwd)"

  local certs_root
  certs_root="${CERTS_DIR:-${dir%/}/certs}"
  if [[ "$certs_root" != /* ]]; then
    certs_root="${dir%/}/${certs_root#./}"
  fi
  certs_root="${certs_root%/}"

  local user group
  # Prefer invoking user when run via sudo; avoids chowning repo to root
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && id -u "$SUDO_USER" >/dev/null 2>&1; then
    user="$SUDO_USER"
    group="$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")"
  else
    user="$(id -un 2>/dev/null || echo "$USER")"
    group="$(id -gn 2>/dev/null || echo "$USER")"
  fi

  # Detect if any file is not owned by the effective user/group
  local need_own="false"
  if find "$dir" \( ! -user "$user" -o ! -group "$group" \) -print -quit 2>/dev/null | grep -q .; then
    need_own="true"
  fi

  if [ "$need_own" = "true" ]; then
    if [ "$EUID" -eq 0 ]; then
      chown -R "$user":"$group" "$dir" 2>/dev/null || true
    else
      _print_sudo_hint "$dir"
    fi
  fi

  # Standardize permissions while preserving executables.
  # Avoid following symlinks
  find "$dir" -type d -exec chmod 755 {} + 2>/dev/null || true

  local restrict_nginx_conf="true"
  if ! _nginx_image_runs_as_root; then
    restrict_nginx_conf="false"
  fi

  local -a restricted_specs=()
  local restricted_spec restricted_dir resolved_dir restricted_mode

  if [ -n "${CERTS_DIR:-}" ]; then
    restricted_specs+=("${CERTS_DIR%/}:750")
  fi
  if [ "$restrict_nginx_conf" = "true" ]; then
    if [ -n "${NGINX_HTTP_CONF_DIR:-}" ]; then
      restricted_specs+=("${NGINX_HTTP_CONF_DIR%/}:750")
    fi
    if [ -n "${NGINX_STREAM_CONF_DIR:-}" ]; then
      restricted_specs+=("${NGINX_STREAM_CONF_DIR%/}:750")
    fi
  fi

  if [ "${#restricted_specs[@]}" -gt 0 ]; then
    for restricted_spec in "${restricted_specs[@]}"; do
      restricted_mode="${restricted_spec##*:}"
      restricted_dir="${restricted_spec%:*}"
      if [ -z "$restricted_dir" ] || [ ! -d "$restricted_dir" ]; then
        continue
      fi
      if ! resolved_dir="$(cd "$restricted_dir" 2>/dev/null && pwd)"; then
        continue
      fi
      case "$resolved_dir" in
      "$dir" | "$dir"/*)
        find "$resolved_dir" -type d -exec chmod "$restricted_mode" {} + 2>/dev/null || true
        ;;
      esac
    done
  fi

  # Normalize file modes without stripping existing executables. Non-executable
  # files are tightened to 644, while any file that already has an execute bit
  # keeps (or regains) a runnable mode.
  local file
  local -a skipped_tls_files=()

  while IFS= read -r -d '' file; do
    if _is_sensitive_tls_file "$file" "$certs_root"; then
      skipped_tls_files+=("$file")
      continue
    fi
    if [ -x "$file" ]; then
      chmod 755 "$file" 2>/dev/null || true
    else
      chmod 644 "$file" 2>/dev/null || true
    fi
  done < <(find "$dir" -type f -print0 2>/dev/null)

  if [ "${#skipped_tls_files[@]}" -gt 0 ]; then
    local tls_file
    for tls_file in "${skipped_tls_files[@]}"; do
      _ensure_tls_permissions "$tls_file"
    done
  fi

  # Ensure critical helper scripts remain executable even if their mode was
  # previously stripped.
  local script
  for script in \
    "$BASE_DIR/dockistrate.sh" \
    "$BASE_DIR/tests/run.sh" \
    "$BASE_DIR/scripts/update-function-reference-appendices.sh" \
    "$BASE_DIR/scripts/render-function-reference-html.sh" \
    "$BASE_DIR/tests/clean_all_regression.sh" \
    "$BASE_DIR/tests/remove_backend_escaping.sh" \
    "$BASE_DIR/tests/docker_opts_parsing.sh" \
    "$BASE_DIR/tests/certs_timestamp.sh" \
    "$BASE_DIR/tests/integration/test_cli.sh" \
    "$BASE_DIR/tests/integration/test_feature_configs.sh" \
    "$BASE_DIR/tests/mocks/docker"; do
    if [ -f "$script" ]; then
      chmod 755 "$script" 2>/dev/null || true
    fi
  done

  if declare -F ensure_runtime_state_permissions >/dev/null 2>&1; then
    ensure_runtime_state_permissions
  fi

  echo "[Info] Permissions normalization complete under: $dir"
  if [ "$need_own" = "true" ] && [ "$EUID" -ne 0 ]; then
    echo "[Warn] Some ownerships may remain unchanged. Re-run with sudo if necessary." >&2
  fi
}

function _nginx_image_runs_as_root() {
  local user=""
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  if [ -n "${NGINX_CONTAINER_NAME:-}" ] && nginx_container_is_managed; then
    user="$(docker inspect -f '{{.Config.User}}' "$NGINX_CONTAINER_NAME" 2>/dev/null || true)"
  elif [ -n "${NGINX_IMAGE:-}" ] && docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
    user="$(docker image inspect "$NGINX_IMAGE" --format '{{.Config.User}}' 2>/dev/null || true)"
  fi

  case "$user" in
  "" | "0" | "0:0" | "root" | "root:root")
    return 0
    ;;
  esac

  return 1
}


# Dedicated load sentinel for entrypoints that source this helper directly.
function __dockistrate_fix_permissions_loaded() {
  :
}
