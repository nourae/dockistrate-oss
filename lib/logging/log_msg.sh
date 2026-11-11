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
      echo "[Warn] Log entry was not saved: private log storage is unavailable." >&2
      return 0
    fi
    ensure_log_writable "$log_file" || {
      echo "[Warn] Log entry was not saved: private log storage is unavailable." >&2
      return 0
    }
    if ! { printf '[%s] %s\n' "$timestamp" "$*" >>"$log_file"; } 2>/dev/null; then
      echo "[Warn] Log entry was not saved: private log write failed." >&2
      return 0
    fi
    if [ "${VERBOSE:-false}" = true ]; then
      printf '[%s] %s\n' "$timestamp" "$*"
    fi
  fi
}
