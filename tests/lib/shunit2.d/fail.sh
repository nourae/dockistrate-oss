#!/usr/bin/env bash

fail() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -gt 1 ]; then
    _shunit_error "fail() requires zero or one arguments; $# given"
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 1 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi

  _shunit_assertFail "${shunit_message_}"

  unset shunit_message_
  return ${SHUNIT_FALSE}
}
