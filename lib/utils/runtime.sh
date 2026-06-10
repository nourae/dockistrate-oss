# shellcheck shell=bash

function xtrace_disable() {
  local __outvar="${1:-}"
  require_valid_var_name "$__outvar" || return 1
  local was_on="false"
  case "$-" in
  *x*) was_on="true" ;;
  esac
  if [ "$was_on" = "true" ]; then
    set +x
  fi
  printf -v "$__outvar" '%s' "$was_on"
}

function xtrace_restore() {
  local state="${1:-false}"
  if [ "$state" = "true" ]; then
    set -x
  fi
}
