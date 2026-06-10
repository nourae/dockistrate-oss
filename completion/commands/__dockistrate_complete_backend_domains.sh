#!/usr/bin/env bash

__dockistrate_complete_backend_domains() {
  local domains
  domains="$(__dockistrate_backend_domains)"
  if [ -n "$domains" ]; then
    COMPREPLY=($(compgen -W "$domains" -- "$cur"))
  fi
}
