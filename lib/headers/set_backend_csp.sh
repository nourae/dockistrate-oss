# shellcheck shell=bash

function set_backend_csp() {
  local domain="${1:-}" val="${2:-}"
  if [ -z "$domain" ] || [ -z "$val" ]; then
    echo "[Usage] set-backend-csp <domain> <policy|off>"
    exit 1
  fi
  local norm
  norm="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  if [ "$norm" = "off" ]; then
    remove_backend_header "$domain" response Content-Security-Policy
  else
    set_backend_header "$domain" response Content-Security-Policy "$val"
  fi
}

# Build header include files from stored definitions
