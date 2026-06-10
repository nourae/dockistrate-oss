#!/usr/bin/env bash

_dockistrate_complete_port_tls_commands() {
  local command="$1"

  case "$command" in
  set-port-http3)
    if [[ $cword -eq 2 ]]; then
      __dockistrate_complete_all_ports
      return 0
    elif [[ $cword -eq 3 ]]; then
      COMPREPLY=($(compgen -W "on off" -- "$cur"))
      return 0
    elif [[ $cword -eq 4 ]]; then
      COMPREPLY=($(compgen -W "auto off custom" -- "$cur"))
      return 0
    fi
    ;;
  list-port-http3)
    if [[ $cword -eq 2 ]]; then
      __dockistrate_complete_all_ports
      return 0
    fi
    ;;
  set-port-tls-protocols | remove-port-tls-protocols | \
    set-port-tls-ciphers | remove-port-tls-ciphers)
    if [[ $cword -eq 2 ]]; then
      __dockistrate_complete_all_ports
      return 0
    fi
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_port_tls_commands)
