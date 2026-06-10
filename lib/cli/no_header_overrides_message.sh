# shellcheck shell=bash

function no_header_overrides_message() {
  local cmd="$1" msg
  case "$cmd" in
  remove-header | update-header)
    local type="${CURRENT_ARGS[0]:-}"
    if [ -n "$type" ]; then
      msg="[Info] No global ${type} headers configured"
    else
      msg="[Info] No global headers configured"
    fi
    ;;
  remove-backend-header | update-backend-header)
    local domain="${CURRENT_ARGS[0]:-}" type="${CURRENT_ARGS[1]:-}"
    if [ -n "$domain" ] && [ -n "$type" ]; then
      msg="[Info] No ${type} headers configured for ${domain}"
    else
      msg="[Info] No backend headers configured"
    fi
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
