#!/usr/bin/env bash

_shunit_fatal() {
  ${__SHUNIT_CMD_ECHO_ESC} \
    "${__shunit_ansi_red}shunit2:FATAL${__shunit_ansi_none} $*" >&2
  exit ${SHUNIT_ERROR}
}
