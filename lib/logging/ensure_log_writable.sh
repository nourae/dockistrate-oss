# shellcheck shell=bash
ENSURE_LOG_WRITABLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F _effective_user >/dev/null 2>&1 && [ -f "${ENSURE_LOG_WRITABLE_DIR}/_effective_user.sh" ]; then
  # Support direct sourcing of this helper without requiring lib/logging.sh first.
  source "${ENSURE_LOG_WRITABLE_DIR}/_effective_user.sh"
fi
if ! declare -F __dockistrate_permissions_common_loaded >/dev/null 2>&1; then
  # Support direct sourcing of log entrypoints before config/runtime bootstrap.
  # shellcheck source=../permissions/common.sh
  source "${ENSURE_LOG_WRITABLE_DIR}/../permissions/common.sh"
fi

function ensure_log_writable() {
  local file="${1:-}"
  local dir
  [ -n "$file" ] || return 1
  dir="$(dirname "$file" && printf '.')" || return 1
  dir="${dir%$'\n.'}"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$dir" "log directory" || return 1
    runtime_state_path_guard_if_declared "$file" "log file" || return 1
  fi
  if ! (umask 077; mkdir -p "$dir") 2>/dev/null || [ -L "$dir" ] || [ ! -d "$dir" ]; then
    return 1
  fi
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$dir" "log directory" || return 1
    runtime_state_path_guard_if_declared "$file" "log file" || return 1
  fi
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    # Never create a group-readable window or overwrite an unexpected new path.
    (umask 077; set -o noclobber; : >"$file") 2>/dev/null || return 1
  fi
  _ensure_private_file_permissions "$file" || return 1
  # If running under sudo/root, try to fix ownership to the invoking user to avoid future lockouts
  if [ "$EUID" -eq 0 ]; then
    local user group
    user="$(_effective_user)"
    group="$(id -gn "$user" 2>/dev/null || echo "$user")"
    chown "$user":"$group" "$dir" "$file" 2>/dev/null || true
  fi
  # Bootstrap owns standard directory modes. Preserve private custom parents
  # (for example a log inside a 0700 backup directory) instead of widening them.
  _ensure_private_file_permissions "$file" || return 1
  [ -w "$file" ]
}
