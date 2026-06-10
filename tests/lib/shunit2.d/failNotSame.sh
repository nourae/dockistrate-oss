#!/usr/bin/env bash

failNotSame() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 2 -o $# -gt 3 ]; then
    _shunit_error "failNotSame() requires one or two arguments; $# given"
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 3 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi
  failNotEquals "${shunit_message_}" "$1" "$2"
  shunit_return=$?

  unset shunit_message_
  return ${shunit_return}
}
