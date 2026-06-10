#!/usr/bin/env bash

__dockistrate_complete_ports_for_domain() {
  local ports
  ports="$(__dockistrate_ports_for_domain "$1")"
  if [ -n "$ports" ]; then
    COMPREPLY=($(compgen -W "$ports" -- "$cur"))
  fi
}
