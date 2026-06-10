#!/usr/bin/env bash

_shunit_colors() {
  _shunit_tput_=$(${SHUNIT_CMD_TPUT} colors 2>/dev/null)
  if command [ $? -eq 0 ]; then
    echo "${_shunit_tput_}"
  else
    echo 16
  fi
  unset _shunit_tput_
}
