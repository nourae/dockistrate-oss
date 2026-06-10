#!/usr/bin/env bash

_shunit_warn() {
  ${__SHUNIT_CMD_ECHO_ESC} \
    "${__shunit_ansi_yellow}shunit2:WARN${__shunit_ansi_none} $*" >&2
}
