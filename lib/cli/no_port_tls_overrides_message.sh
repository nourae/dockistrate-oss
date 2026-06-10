# shellcheck shell=bash

function no_port_tls_overrides_message() {
  local cmd="$1" msg
  case "$cmd" in
  remove-port-tls-protocols)
    msg="[Info] No port TLS protocol overrides configured"
    ;;
  remove-port-tls-ciphers)
    msg="[Info] No port TLS cipher overrides configured"
    ;;
  set-port-tls-protocols | set-port-tls-ciphers)
    msg="[Info] No HTTPS ports configured"
    ;;
  *)
    return 1
    ;;
  esac
  echo "$msg"
  if [ "$INTERACTIVE" = true ]; then
    read -rp "Press Enter to continue..." _
  fi
  return 0
}
