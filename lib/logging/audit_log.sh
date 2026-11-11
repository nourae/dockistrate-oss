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
  local audit_file="${AUDIT_LOG_FILE:-}"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  normalized_message="$(_normalize_audit_log_message "$*")"
  if [ -z "$audit_file" ]; then
    echo "[Warn] Audit entry was not saved: private log storage is unavailable." >&2
    return 0
  fi
  if ! _ensure_private_file_permissions_if_exists "${audit_file}.1" ||
    ! ensure_log_writable "$audit_file"; then
    echo "[Warn] Audit entry was not saved: private log storage is unavailable." >&2
    return 0
  fi
  if [ -f "$audit_file" ] && [ -r "$audit_file" ]; then
    local size
    size=$(wc -c <"$audit_file" 2>/dev/null || echo 0)
    if [ "$size" -gt 1048576 ] 2>/dev/null; then
      if ! mv -f "$audit_file" "${audit_file}.1" 2>/dev/null ||
        ! _ensure_private_file_permissions "${audit_file}.1" ||
        ! ensure_log_writable "$audit_file"; then
        echo "[Warn] Audit entry was not saved: private log rotation failed." >&2
        return 0
      fi
    fi
  fi
  if ! {
    if [ -n "$normalized_message" ]; then
      printf '[%s] %s\n' "$timestamp" "$normalized_message" >>"$audit_file"
    else
      printf '[%s]\n' "$timestamp" >>"$audit_file"
    fi
  } 2>/dev/null; then
    echo "[Warn] Audit entry was not saved: private log write failed." >&2
  fi
}
