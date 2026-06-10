# shellcheck shell=bash

# Helper to summarize a security rule condition for interactive prompts.
function summarize_cond() {
  local _s="$1" _n="$2" _c="$3" _v="$4" lbl
  case "$_s" in
  header | cookie | arg | var | ip) lbl="${_s}:${_n}" ;;
  *) lbl="${_s}" ;;
  esac
  printf '%s %s %s' "$lbl" "${_c:-}" "${_v:--}"
}
