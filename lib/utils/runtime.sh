# shellcheck shell=bash

function xtrace_start() {
  local started_at
  # Bash 3 has no builtin wall-clock formatter. Resolve the session anchor once;
  # SECONDS and arithmetic expansion keep every later trace prefix process-free.
  DOCKISTRATE_TRACE_START_SECONDS="${SECONDS:-0}"
  started_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
  PS4='+ [session=$$ elapsed=$(( ${SECONDS:-0} - ${DOCKISTRATE_TRACE_START_SECONDS:-0} ))s] [CMD] '
  set -x
  # A traced no-op uses the same destination as all other traces, including the
  # Bash 3 stderr/tee route and configurations with ordinary logging disabled.
  : "Verbose trace session $$ started at ${started_at}; offsets are elapsed whole seconds"
}

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
