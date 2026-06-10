#!/usr/bin/env bash

_dockistrate_complete_misc() {
  local command="$1" tag="" words="--require-backup"

  case "$command" in
  fix-permissions)
    COMPREPLY=($(compgen -W "--certbot-darwin-user" -- "$cur") $(compgen -f -- "$cur"))
    return 0
    ;;
  help)
    if [[ "${cword:-0}" -eq 2 ]]; then
      COMPREPLY=($(compgen -W "update" -- "$cur"))
    else
      COMPREPLY=()
    fi
    return 0
    ;;
  upgrade-preflight)
    if [[ "$cur" == --* ]]; then
      COMPREPLY=($(compgen -W "--require-backup" -- "$cur"))
      return 0
    fi
    while IFS= read -r tag; do
      if [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        words="${words} ${tag}"
      fi
    done < <(git -C "${__dockistrate_completion_dir}/.." tag -l 'v*.*.*' 2>/dev/null)
    COMPREPLY=($(compgen -W "$words" -- "$cur"))
    return 0
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_misc)
