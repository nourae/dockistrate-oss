# shellcheck shell=bash

# Bash 3-compatible associative map for command descriptions.
COMMAND_DESCRIPTION_PREFIX="CMD_DESC__"
readonly COMMAND_DESCRIPTION_PREFIX

function _set_command_description() {
  local key="$1" desc="$2" var
  var="${COMMAND_DESCRIPTION_PREFIX}${key//[^A-Za-z0-9_]/_}"
  printf -v "$var" '%s' "$desc"
}
