#!/usr/bin/env bash

__dockistrate_complete_all_ports() {
  local ports
  ports="$(__dockistrate_all_ports)"
  if [ -n "$ports" ]; then
    COMPREPLY=($(compgen -W "$ports" -- "$cur"))
  fi
}
