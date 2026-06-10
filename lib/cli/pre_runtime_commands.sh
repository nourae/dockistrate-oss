# shellcheck shell=bash

function dockistrate_command_skips_runtime_prep() {
  local cmd="${1:-}"

  case "$cmd" in
  help | help-update | upgrade-preflight)
    return 0
    ;;
  esac

  return 1
}
