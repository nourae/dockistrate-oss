# shellcheck shell=bash

function _source_modules() {
  local module
  for module in "$@"; do
    source "$module"
  done
}
