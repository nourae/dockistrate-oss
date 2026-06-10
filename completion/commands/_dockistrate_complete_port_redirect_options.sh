#!/usr/bin/env bash

_dockistrate_complete_port_redirect_options() {
  local command="$1"

  case "$command" in
  set-port-redirect)
    if [[ $cword -eq 4 ]]; then
      COMPREPLY=($(compgen -W "on off yes no" -- "$cur"))
      return 0
    elif [[ $cword -eq 5 ]]; then
      COMPREPLY=($(compgen -W "301 302 308" -- "$cur"))
      return 0
    fi
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_port_redirect_options)
