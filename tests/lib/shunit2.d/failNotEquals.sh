#!/usr/bin/env bash

failNotEquals() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 2 -o $# -gt 3 ]; then
    _shunit_error "failNotEquals() requires one or two arguments; $# given"
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

  shunit_message_=${shunit_message_%% }
  _shunit_assertFail "${shunit_message_:+${shunit_message_} }expected:<${shunit_expected_}> but was:<${shunit_actual_}>"

  unset shunit_message_ shunit_expected_ shunit_actual_
  return ${SHUNIT_FALSE}
}
