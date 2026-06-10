#!/usr/bin/env bash

failNotFound() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 1 -o $# -gt 2 ]; then
    _shunit_error "failNotFound() requires one or two arguments; $# given"
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 2 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi
  shunit_content_=$1

  shunit_message_=${shunit_message_%% }
  _shunit_assertFail "${shunit_message_:+${shunit_message_} }Not found:<${shunit_content_}>"

  unset shunit_message_ shunit_content_
  return ${SHUNIT_FALSE}
}
