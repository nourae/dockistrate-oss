#!/usr/bin/env bash

_shunit_generateReport() {
  command [ "${__shunit_reportGenerated}" -eq ${SHUNIT_TRUE} ] && return

  _shunit_ok_=${SHUNIT_TRUE}

  # If no exit code was provided, determine an appropriate one.
  command [ "${__shunit_testsFailed}" -gt 0 \
    -o ${__shunit_testSuccess} -eq ${SHUNIT_FALSE} ] &&
    _shunit_ok_=${SHUNIT_FALSE}

  echo
  _shunit_msg_="Ran ${__shunit_ansi_cyan}${__shunit_testsTotal}${__shunit_ansi_none}"
  if command [ "${__shunit_testsTotal}" -eq 1 ]; then
    ${__SHUNIT_CMD_ECHO_ESC} "${_shunit_msg_} test."
  else
    ${__SHUNIT_CMD_ECHO_ESC} "${_shunit_msg_} tests."
  fi

  if command [ ${_shunit_ok_} -eq ${SHUNIT_TRUE} ]; then
    _shunit_msg_="${__shunit_ansi_green}OK${__shunit_ansi_none}"
    command [ "${__shunit_assertsSkipped}" -gt 0 ] &&
      _shunit_msg_="${_shunit_msg_} (${__shunit_ansi_yellow}skipped=${__shunit_assertsSkipped}${__shunit_ansi_none})"
  else
    _shunit_msg_="${__shunit_ansi_red}FAILED${__shunit_ansi_none}"
    _shunit_msg_="${_shunit_msg_} (${__shunit_ansi_red}failures=${__shunit_assertsFailed}${__shunit_ansi_none}"
    command [ "${__shunit_assertsSkipped}" -gt 0 ] &&
      _shunit_msg_="${_shunit_msg_},${__shunit_ansi_yellow}skipped=${__shunit_assertsSkipped}${__shunit_ansi_none}"
    _shunit_msg_="${_shunit_msg_})"
  fi

  echo
  ${__SHUNIT_CMD_ECHO_ESC} "${_shunit_msg_}"
  __shunit_reportGenerated=${SHUNIT_TRUE}

  unset _shunit_msg_ _shunit_ok_
}
