#!/usr/bin/env bash

_shunit_escapeCharInStr() {
  command [ -n "$2" ] || return # No point in doing work on an empty string.

  # Note: using shorter variable names to prevent conflicts with
  # _shunit_escapeCharactersInString().
  _shunit_c_=$1
  _shunit_s_=$2

  # Escape the character.
  # shellcheck disable=SC1003,SC2086
  # shunit2 uses this sed form to escape literal assertion helper input.
  echo ''${_shunit_s_}'' | command sed 's/\'${_shunit_c_}'/\\\'${_shunit_c_}'/g' # input-validation-audit: ignore

  unset _shunit_c_ _shunit_s_
}
