# shellcheck shell=bash

function set_backend_hsts() {
  local domain="${1:-}" val="${2:-}"
  if [ -z "$domain" ] || [ -z "$val" ]; then
    echo "[Usage] set-backend-hsts <domain> <value|off>"
    exit 1
  fi
  local norm
  norm="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  if [ "$norm" = "off" ]; then
    remove_backend_header "$domain" response Strict-Transport-Security
  else
    set_backend_header "$domain" response Strict-Transport-Security "$val"
  fi
}
