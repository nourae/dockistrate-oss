#!/usr/bin/env bash

_shunit_error() {
  ${__SHUNIT_CMD_ECHO_ESC} \
    "${__shunit_ansi_red}shunit2:ERROR${__shunit_ansi_none} $*" >&2
}
