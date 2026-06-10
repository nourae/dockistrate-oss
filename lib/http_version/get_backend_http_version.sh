# shellcheck shell=bash

function get_backend_http_version() {
  local domain="${1:-}"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  local ver="$HTTP_VERSION"
  if [ -n "$domain" ] && [ -f "$BACKEND_HTTP_FILE" ]; then
    local custom
    custom="$(state_csv_get_two_col_value "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$domain" "" 2>/dev/null || true)"
    [ -n "$custom" ] && ver="$custom"
  fi
  echo "$ver"
}

# Determine proxy_http_version value for a given backend
