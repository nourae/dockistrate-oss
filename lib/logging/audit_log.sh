# shellcheck shell=bash
if ! declare -F ensure_log_writable >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/logging.sh first.
  # shellcheck source=./ensure_log_writable.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure_log_writable.sh"
fi

function _normalize_audit_log_message() {
  local raw_message="${1:-}" normalized=""
  normalized="$(printf '%s' "$raw_message" | LC_ALL=C tr '\000-\037\177' ' ' | LC_ALL=C tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  printf '%s' "$normalized"
}

function audit_log() {
  local timestamp
  local normalized_message
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  normalized_message="$(_normalize_audit_log_message "$*")"
  ensure_log_writable "$AUDIT_LOG_FILE" || {
    if [ -n "$normalized_message" ]; then
      echo "[$timestamp] $normalized_message" >&2
    else
      echo "[$timestamp]" >&2
    fi
    return 0
  }
  if [ -f "$AUDIT_LOG_FILE" ] && [ -r "$AUDIT_LOG_FILE" ]; then
    local size
    size=$(wc -c <"$AUDIT_LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt 1048576 ] 2>/dev/null; then
      mv "$AUDIT_LOG_FILE" "${AUDIT_LOG_FILE}.1" 2>/dev/null || true
      # Touch a fresh log and set ownership appropriately
      ensure_log_writable "$AUDIT_LOG_FILE" || return 0
    fi
  fi
  if [ -w "$AUDIT_LOG_FILE" ] || touch "$AUDIT_LOG_FILE" &>/dev/null; then
    if [ -n "$normalized_message" ]; then
      echo "[$timestamp] $normalized_message" >>"$AUDIT_LOG_FILE"
    else
      echo "[$timestamp]" >>"$AUDIT_LOG_FILE"
    fi
  else
    # Fall back to stderr if not writable
    if [ -n "$normalized_message" ]; then
      echo "[$timestamp] $normalized_message" >&2
    else
      echo "[$timestamp]" >&2
    fi
  fi
}
