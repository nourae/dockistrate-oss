# shellcheck shell=bash

# Return newline separated choices for a specific argument if available
function get_arg_choices() {
  local cmd="$1" arg="$2"
  local fn="__arg_choices_${arg}"
  if declare -f "$fn" >/dev/null 2>&1; then
    "$fn" "$cmd" "$arg"
  fi
}
