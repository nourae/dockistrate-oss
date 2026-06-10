#!/usr/bin/env bash

_shunit_cleanup() {
  _shunit_name_=$1

  case "${_shunit_name_}" in
  EXIT) ;;
  INT) _shunit_signal_=130 ;;  # 2+128
  TERM) _shunit_signal_=143 ;; # 15+128
  *)
    _shunit_error "unrecognized trap value (${_shunit_name_})"
    _shunit_signal_=0
    ;;
  esac
  if command [ "${_shunit_name_}" != 'EXIT' ]; then
    _shunit_warn "trapped and now handling the (${_shunit_name_}) signal"
  fi

  # Do our work.
  if command [ ${__shunit_clean} -eq ${SHUNIT_FALSE} ]; then
    # Ensure tear downs are only called once.
    __shunit_clean=${SHUNIT_TRUE}

    tearDown
    command [ $? -eq ${SHUNIT_TRUE} ] ||
      _shunit_warn "tearDown() returned non-zero return code."
    oneTimeTearDown
    command [ $? -eq ${SHUNIT_TRUE} ] ||
      _shunit_warn "oneTimeTearDown() returned non-zero return code."

    command rm -fr "${__shunit_tmpDir}"
  fi

  if command [ "${_shunit_name_}" != 'EXIT' ]; then
    # Handle all non-EXIT signals.
    trap - 0 # Disable EXIT trap.
    exit ${_shunit_signal_}
  elif command [ ${__shunit_reportGenerated} -eq ${SHUNIT_FALSE} ]; then
    _shunit_assertFail 'unknown failure encountered running a test'
    _shunit_generateReport
    exit ${SHUNIT_ERROR}
  fi

  unset _shunit_name_ _shunit_signal_
}
