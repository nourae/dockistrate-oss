# shellcheck shell=bash

function get_backend_http_version() {
  local domain="${1:-}"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  local ver="$HTTP_VERSION"
  _require_persisted_settings_validation || return 1
  if [ -n "$domain" ]; then
    local custom
    custom="$(get_validated_backend_setting_override "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" HTTP_VERSION "$domain")" || return 1
    [ -n "$custom" ] && ver="$custom"
  fi
  validate_persisted_setting HTTP_VERSION "$ver" || return 1
  printf '%s\n' "$ver"
}

# Determine proxy_http_version value for a given backend
