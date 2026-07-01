# shellcheck shell=bash
if ! declare -F ensure_log_writable >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/logging.sh first.
  # shellcheck source=./ensure_log_writable.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure_log_writable.sh"
fi

function log_msg() {
  if [ "${ENABLE_LOGGING:-false}" = true ]; then
    local timestamp
    local log_file="${LOG_FILE:-}"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ -z "$log_file" ]; then
      echo "[$timestamp] $*"
      return 0
    fi
    ensure_log_writable "$log_file" || {
      echo "[$timestamp] $*"
      return 0
    }
    if [ -w "$log_file" ] || touch "$log_file" &>/dev/null; then
      if [ "${VERBOSE:-false}" = true ]; then
        echo "[$timestamp] $*" | tee -a "$log_file"
      else
        echo "[$timestamp] $*" | tee -a "$log_file" >/dev/null
      fi
    else
      # Fall back to stdout/stderr without failing the whole run
      echo "[$timestamp] $*"
    fi
  fi
}
