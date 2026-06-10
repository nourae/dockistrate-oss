#!/usr/bin/env bash

_dockistrate_complete_headers() {
  local command="$1"

  case "$command" in
  remove-backend-header)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_HEADERS_FILE" ]; then
      local domains
      domains=$(awk -F'|' '{print $1}' "$BACKEND_HEADERS_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=($(compgen -W "request response" -- "$cur"))
      return 0
    fi
    ;;
  list-backend-headers)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_HEADERS_FILE" ]; then
      local domains
      domains=$(awk -F'|' '{print $1}' "$BACKEND_HEADERS_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    ;;
  add-backend-header | update-backend-header)
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=($(compgen -W "request response" -- "$cur"))
      return 0
    fi
    ;;
  set-backend-client-ip-header | set-backend-proxy-ip-header)
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=($(compgen -W "off" -- "$cur"))
      return 0
    fi
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_headers)
