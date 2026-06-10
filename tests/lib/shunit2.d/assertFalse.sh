#!/usr/bin/env bash

assertFalse() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 1 -o $# -gt 2 ]; then
    _shunit_error "assertFalse() requires one or two arguments; $# given"
    _shunit_assertFail
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 2 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi
  shunit_condition_=$1

  # See if condition is an integer, i.e. a return value.
  shunit_match_=$(expr "${shunit_condition_}" : '\([0-9]*\)')
  shunit_return=${SHUNIT_TRUE}
  if command [ -z "${shunit_condition_}" ]; then
    # Null condition.
    shunit_return=${SHUNIT_FALSE}
  elif command [ -n "${shunit_match_}" -a "${shunit_condition_}" = "${shunit_match_}" ]; then
    # Possible return value. Treating 0 as true, and non-zero as false.
    command [ "${shunit_condition_}" -eq 0 ] && shunit_return=${SHUNIT_FALSE}
  else
    # Hopefully... a condition.
    # shunit2 intentionally evaluates assertion expressions provided by the test.
    (eval "${shunit_condition_}") >/dev/null 2>&1 # input-validation-audit: ignore
    command [ $? -eq 0 ] && shunit_return=${SHUNIT_FALSE}
  fi

  # Record the test.
  if command [ "${shunit_return}" -eq "${SHUNIT_TRUE}" ]; then
    _shunit_assertPass
  else
    _shunit_assertFail "${shunit_message_}"
  fi

  unset shunit_message_ shunit_condition_ shunit_match_
  return "${shunit_return}"
}
