# shellcheck shell=bash

function is_back_input() {
  local val="$1"
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  case "$val" in
  back | b | __back__) return 0 ;;
  esac
  return 1
}
