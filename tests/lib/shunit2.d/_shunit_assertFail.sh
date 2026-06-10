#!/usr/bin/env bash

_shunit_assertFail() {
  __shunit_testSuccess=${SHUNIT_FALSE}
  _shunit_incFailedCount

  \[ $# -gt 0 ] && ${__SHUNIT_CMD_ECHO_ESC} \
    "${__shunit_ansi_red}ASSERT:${__shunit_ansi_none}$*"
}
