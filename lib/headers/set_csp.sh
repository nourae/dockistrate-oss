# shellcheck shell=bash

function set_csp() {
  local val="${1:-}"
  [ -z "$val" ] && {
    echo "[Usage] set-csp <policy|off>"
    exit 1
  }
  local norm
  norm="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  if [ "$norm" = "off" ]; then
    remove_header response Content-Security-Policy
  else
    set_header response Content-Security-Policy "$val"
  fi
}
