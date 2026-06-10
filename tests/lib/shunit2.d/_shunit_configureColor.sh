#!/usr/bin/env bash

_shunit_configureColor() {
  _shunit_color_=${SHUNIT_FALSE} # By default, no color.
  case $1 in
  'always') _shunit_color_=${SHUNIT_TRUE} ;;
  'auto')
    command [ "$(_shunit_colors)" -ge 8 ] && _shunit_color_=${SHUNIT_TRUE}
    ;;
  'none') ;;
  *) _shunit_fatal "unrecognized color option '$1'" ;;
  esac

  case ${_shunit_color_} in
  ${SHUNIT_TRUE})
    __shunit_ansi_none=${__SHUNIT_ANSI_NONE}
    __shunit_ansi_red=${__SHUNIT_ANSI_RED}
    __shunit_ansi_green=${__SHUNIT_ANSI_GREEN}
    __shunit_ansi_yellow=${__SHUNIT_ANSI_YELLOW}
    __shunit_ansi_cyan=${__SHUNIT_ANSI_CYAN}
    ;;
  ${SHUNIT_FALSE})
    __shunit_ansi_none=''
    __shunit_ansi_red=''
    __shunit_ansi_green=''
    __shunit_ansi_yellow=''
    __shunit_ansi_cyan=''
    ;;
  esac

  unset _shunit_color_ _shunit_tput_
}
