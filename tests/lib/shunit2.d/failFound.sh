#!/usr/bin/env bash

failFound() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 1 -o $# -gt 2 ]; then
    _shunit_error "failFound() requires one or two arguments; $# given"
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 2 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi

  shunit_message_=${shunit_message_%% }
  _shunit_assertFail "${shunit_message_:+${shunit_message_} }Found"

  unset shunit_message_
  return ${SHUNIT_FALSE}
}
