#!/usr/bin/env bash

_dockistrate_complete_port_domain_commands() {
  local command="$1"

  case "$command" in
  remove-port | update-port | set-port-redirect | \
    remove-port-redirect | enable-ws | disable-ws | \
    add-path-option | update-path-option | remove-path-option | list-path-options)
    if [[ $cword -eq 3 ]]; then
      __dockistrate_complete_ports_for_domain "${words[2]}"
      return 0
    fi
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_port_domain_commands)
