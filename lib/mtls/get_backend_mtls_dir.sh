# shellcheck shell=bash

function get_backend_mtls_dir() {
  local domain="${1:-}"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  local dir=""
  if [ -n "$domain" ] && [ -f "$BACKEND_MTLS_FILE" ]; then
    dir="$(state_csv_get_two_col_value "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$domain" "" 2>/dev/null || true)"
  fi
  # For dedicated hosts, fall back to target domain's mTLS config if:
  # 1. No explicit config exists for the dedicated host
  # 2. Inheritance is enabled for mTLS
  if [ -z "$dir" ]; then
    local target_domain
    target_domain="$(backend_for_dedicated_host "$domain")"
    if [ -n "$target_domain" ]; then
      # Check if inheritance is enabled (defaults to yes if function not available)
      local should_inherit="yes"
      if command -v should_inherit_mtls >/dev/null 2>&1; then
        should_inherit_mtls "$domain" && should_inherit="yes" || should_inherit="no"
      fi
      if [ "$should_inherit" = "yes" ] && [ -f "$BACKEND_MTLS_FILE" ]; then
        dir="$(state_csv_get_two_col_value "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$target_domain" "" 2>/dev/null || true)"
      fi
    fi
  fi
  echo "$dir"
}
