# shellcheck shell=bash

function set_hsts() {
  local val="${1:-}"
  [ -z "$val" ] && {
    echo "[Usage] set-hsts <value|off>"
    exit 1
  }
  local norm
  norm="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  if [ "$norm" = "off" ]; then
    remove_header response Strict-Transport-Security
  else
    set_header response Strict-Transport-Security "$val"
  fi
}
