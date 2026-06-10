#!/usr/bin/env bash

assertNull() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 1 -o $# -gt 2 ]; then
    _shunit_error "assertNull() requires one or two arguments; $# given"
    _shunit_assertFail
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 2 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi
  assertTrue "${shunit_message_}" "[ -z '$1' ]"
  shunit_return=$?

  unset shunit_message_
  return ${shunit_return}
}
