# shellcheck shell=bash
if ! declare -F ensure_log_writable >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/logging.sh first.
  # shellcheck source=./ensure_log_writable.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure_log_writable.sh"
fi

function log_msg() {
  if [ "$ENABLE_LOGGING" = true ]; then
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    ensure_log_writable "$LOG_FILE" || {
      echo "[$timestamp] $*"
      return 0
    }
    if [ -w "$LOG_FILE" ] || touch "$LOG_FILE" &>/dev/null; then
      if [ "${VERBOSE:-false}" = true ]; then
        echo "[$timestamp] $*" | tee -a "$LOG_FILE"
      else
        echo "[$timestamp] $*" | tee -a "$LOG_FILE" >/dev/null
      fi
    else
      # Fall back to stdout/stderr without failing the whole run
      echo "[$timestamp] $*"
    fi
  fi
}
