#!/usr/bin/env bash

assertNotContains() {
  # shellcheck disable=SC2090
  ${_SHUNIT_LINENO_}
  if command [ $# -lt 2 -o $# -gt 3 ]; then
    _shunit_error "assertNotContains() requires two or three arguments; $# given"
    _shunit_assertFail
    return ${SHUNIT_ERROR}
  fi
  _shunit_shouldSkip && return ${SHUNIT_TRUE}

  shunit_message_=${__shunit_lineno}
  if command [ $# -eq 3 ]; then
    shunit_message_="${shunit_message_}$1"
    shift
  fi
  shunit_container_=$1
  shunit_content_=$2

  shunit_return=${SHUNIT_TRUE}
  if echo "$shunit_container_" | grep -F -- "$shunit_content_" >/dev/null; then
    failFound "${shunit_message_}" "${shunit_content_}"
    shunit_return=${SHUNIT_FALSE}
  else
    _shunit_assertPass
  fi

  unset shunit_message_ shunit_container_ shunit_content_
  return ${shunit_return}
}
