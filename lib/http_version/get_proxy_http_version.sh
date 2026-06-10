# shellcheck shell=bash

function get_proxy_http_version() {
  local domain="${1:-}"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  local ver
  ver=$(get_backend_http_version "$domain")
  if [ "$ver" = "http2" ]; then
    echo "1.1"
  else
    echo "${ver/http/}"
  fi
}
