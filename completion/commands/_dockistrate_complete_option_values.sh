#!/usr/bin/env bash

_dockistrate_complete_option_values() {
  local command="$1"

  case "$command" in
  start-nginx)
    if [[ "$prev" == "--nginx-image" ]]; then
      COMPREPLY=($(compgen -W "${NGINX_IMAGE:-nginx:latest} nginx:latest" -- "$cur"))
      return 0
    fi
    if [[ "$prev" == "--docker-opts" ]]; then
      COMPREPLY=()
      return 0
    fi
    if [[ "$cur" == --* ]]; then
      COMPREPLY=($(compgen -W "--nginx-image --docker-opts" -- "$cur"))
      return 0
    fi
    ;;
  add-backend)
    if [[ $cword -eq 5 ]]; then
      COMPREPLY=($(compgen -W "http https tcp udp" -- "$cur"))
      return 0
    fi
    case "$prev" in
    --cert)
      COMPREPLY=($(compgen -W "selfsigned letsencrypt none" -- "$cur") $(compgen -d -- "$cur"))
      return 0
      ;;
    --ws | --expose)
      COMPREPLY=($(compgen -W "yes no" -- "$cur"))
      return 0
      ;;
    --listen)
      COMPREPLY=()
      return 0
      ;;
    --network | --docker-opts)
      COMPREPLY=()
      return 0
      ;;
    esac
    if [[ "$cur" == --* ]]; then
      COMPREPLY=($(compgen -W "--listen --cert --ws --docker-opts --network --no-expose --expose" -- "$cur"))
      return 0
    fi
    ;;
  add-acl)
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=($(compgen -W "l7 l3" -- "$cur"))
      return 0
    elif [[ $cword -eq 4 ]]; then
      COMPREPLY=($(compgen -W "allow deny" -- "$cur"))
      return 0
    fi
    ;;
  set-backend-http-version)
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=($(compgen -W "http1.0 http1.1 http2" -- "$cur"))
      return 0
    fi
    ;;
  set-backend-acl-policy)
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=($(compgen -W "allow deny" -- "$cur"))
      return 0
    fi
    ;;
  set-acl-policy)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "allow deny" -- "$cur"))
      return 0
    fi
    ;;
  set-http-version)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "http1.0 http1.1 http2" -- "$cur"))
      return 0
    fi
    ;;
  set-auto-backups | set-backup-compression)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "true false" -- "$cur"))
      return 0
    fi
    ;;
  set-real-ip-recursive)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "on off" -- "$cur"))
      return 0
    fi
    ;;
  uninstall-all)
    if [[ "$prev" == "--scope" ]]; then
      COMPREPLY=($(compgen -W "backend config all" -- "$cur"))
      return 0
    fi
    if [[ "$cur" == --scope=* ]]; then
      local scope_prefix="--scope="
      local scope_partial="${cur#--scope=}"
      local scope_matches scope
      scope_matches="$(compgen -W "backend config all" -- "$scope_partial")"
      COMPREPLY=()
      for scope in $scope_matches; do
        COMPREPLY+=("${scope_prefix}${scope}")
      done
      return 0
    fi
    COMPREPLY=($(compgen -W "--scope" -- "$cur"))
    return 0
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_option_values)
