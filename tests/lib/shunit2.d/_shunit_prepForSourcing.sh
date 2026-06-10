#!/usr/bin/env bash

_shunit_prepForSourcing() {
  _shunit_script_=$1
  case "${_shunit_script_}" in
  /* | ./*) echo "${_shunit_script_}" ;;
  *) echo "./${_shunit_script_}" ;;
  esac
  unset _shunit_script_
}
