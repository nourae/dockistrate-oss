# shellcheck shell=bash

function mark_current_option() {
  local default="${1:-}"
  [ -n "$default" ] || return 0
  [ -n "${_vals+x}" ] || return 0
  [ -n "${_disp+x}" ] || return 0
  local __trimmed_default __norm_default
  __trimmed_default="$(printf '%s' "$default" | awk '{$1=$1; print}')"
  __norm_default="$(printf '%s' "$__trimmed_default" | tr '[:upper:]' '[:lower:]')"
  local i
  for i in "${!_vals[@]}"; do
    local v="${_vals[$i]}" lbl="${_disp[$i]-}"
    local norm_v
    norm_v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    if [ "$norm_v" = "$__norm_default" ]; then
      lbl+=" (current)"
    fi
    _disp[$i]="$lbl"
  done
}
