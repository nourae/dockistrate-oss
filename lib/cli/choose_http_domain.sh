# shellcheck shell=bash

# Header overrides support backend, ordinary-alias and dedicated identities.
function choose_http_domain() {
  local __var="$1"
  require_valid_var_name "$__var" || return 1
  local list=""
  list="$(__arg_choices_header_domains)" || return 1
  [ -z "$list" ] && {
    echo "[Info] No backends configured." >&2
    return 1
  }
  read_lines_into_array domains "$list"
  local idx
  if ! choose_option idx "Select domain:" "${domains[@]}" "Back"; then
    return 1
  fi
  ((idx == ${#domains[@]})) && return 1
  printf -v "$__var" '%s' "${domains[$idx]}"
}
