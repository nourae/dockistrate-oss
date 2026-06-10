#!/usr/bin/env bash

_shunit_escapeCharactersInString() {
  command [ -n "$1" ] || return # No point in doing work on an empty string.

  _shunit_str_=$1

  # Note: using longer variable names to prevent conflicts with
  # _shunit_escapeCharInStr().
  for _shunit_char_ in '"' '$' "'" '`'; do
    _shunit_str_=$(_shunit_escapeCharInStr "${_shunit_char_}" "${_shunit_str_}")
  done

  echo "${_shunit_str_}"
  unset _shunit_char_ _shunit_str_
}
