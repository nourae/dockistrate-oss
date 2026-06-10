#!/usr/bin/env bash

assertNotEquals() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 2 -o $# -gt 3 ]; then
    _shunit_error "assertNotEquals() requires two or three arguments; $# given"
    _shunit_assertFail
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 3 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi
  shunit_expected_=$1
  shunit_actual_=$2

  shunit_return=${SHUNIT_TRUE}
  if command [ "${shunit_expected_}" != "${shunit_actual_}" ]; then
    _shunit_assertPass
  else
    failSame "${shunit_message_}" "${shunit_expected_}" "${shunit_actual_}"
    shunit_return=${SHUNIT_FALSE}
  fi

  unset shunit_message_ shunit_expected_ shunit_actual_
  return ${shunit_return}
}
