# shellcheck shell=bash
ENSURE_LOG_WRITABLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F _effective_user >/dev/null 2>&1 && [ -f "${ENSURE_LOG_WRITABLE_DIR}/_effective_user.sh" ]; then
  # Support direct sourcing of this helper without requiring lib/logging.sh first.
  source "${ENSURE_LOG_WRITABLE_DIR}/_effective_user.sh"
fi
if ! declare -F __dockistrate_runtime_paths_loaded >/dev/null 2>&1 && [ -f "${ENSURE_LOG_WRITABLE_DIR}/../runtime_paths.sh" ]; then
  # Support direct sourcing of this helper without requiring lib/config.sh first.
  # shellcheck source=../runtime_paths.sh
  source "${ENSURE_LOG_WRITABLE_DIR}/../runtime_paths.sh"
fi

function ensure_log_writable() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$dir" "log directory" || return 1
    runtime_state_path_guard_if_declared "$file" "log file" || return 1
  fi
  mkdir -p "$dir" 2>/dev/null || true
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$dir" "log directory" || return 1
    runtime_state_path_guard_if_declared "$file" "log file" || return 1
  fi
  # Touch may fail if owned by root and we are non-root; that's okay, we fall back later
  touch "$file" 2>/dev/null || true
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$file" "log file" || return 1
  fi
  # If running under sudo/root, try to fix ownership to the invoking user to avoid future lockouts
  if [ "$EUID" -eq 0 ]; then
    local user group
    user="$(_effective_user)"
    group="$(id -gn "$user" 2>/dev/null || echo "$user")"
    chown "$user":"$group" "$dir" "$file" 2>/dev/null || true
  fi
  chmod 750 "$dir" 2>/dev/null || true
  chmod 640 "$file" 2>/dev/null || chmod 600 "$file" 2>/dev/null || true
}
