#!/usr/bin/env bash

assertNotNull() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -gt 2 ]; then # allowing 0 arguments as $1 might actually be null
    _shunit_error "assertNotNull() requires one or two arguments; $# given"
    _shunit_assertFail
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 2 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi
  shunit_actual_=$(_shunit_escapeCharactersInString "${1:-}")
  test -n "${shunit_actual_}"
  assertTrue "${shunit_message_}" $?
  shunit_return=$?

  unset shunit_actual_ shunit_message_
  return ${shunit_return}
}
