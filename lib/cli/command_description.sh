# shellcheck shell=bash

function command_description() {
  local var="${COMMAND_DESCRIPTION_PREFIX}${1//[^A-Za-z0-9_]/_}"
  echo "${!var-}"
}
