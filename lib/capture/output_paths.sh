# shellcheck shell=bash

function _capture_output_helper() {
  if ! declare -F _capture_output_run >/dev/null 2>&1; then
    # shellcheck source=./output_io.sh
    source "${BASH_SOURCE[0]%/*}/output_io.sh" || return 1
  fi
  _capture_output_run "$@"
}

function _capture_output_preflight() {
  [ "$#" -eq 2 ] || return 1
  _capture_output_helper preflight "$1" "$2"
}

function _capture_output_prepare() {
  [ "$#" -eq 4 ] || return 1
  # Avoid dynamic-scope collisions with the caller's output variables.
  case "$1:$2" in
  *_capture_output_*) return 1 ;;
  esac
  local _capture_output_name=""
  for _capture_output_name in "$1" "$2"; do
    case "$_capture_output_name" in
    '' | [!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_]* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) return 1 ;;
    esac
  done
  [ "$1" != "$2" ] || return 1
  local _capture_output_record="" _capture_output_path="" _capture_output_identity=""
  _capture_output_record="$(_capture_output_helper prepare "$3" "$4")" || return 1
  case "$_capture_output_record" in
  *$'\n'*) ;;
  *) return 1 ;;
  esac
  _capture_output_path="${_capture_output_record%$'\n'*}"
  _capture_output_identity="${_capture_output_record##*$'\n'}"
  case "$_capture_output_path" in /*) ;; *) return 1 ;; esac
  case "$_capture_output_identity" in '' | *[!0123456789:]*) return 1 ;; esac
  printf -v "$1" '%s' "$_capture_output_path"
  printf -v "$2" '%s' "$_capture_output_identity"
}

function _capture_output_verify() {
  [ "$#" -eq 3 ] || return 1
  _capture_output_helper verify "$1" "$2" "$3"
}
