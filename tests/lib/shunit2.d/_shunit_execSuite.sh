#!/usr/bin/env bash
# Dockistrate modification notice:
# This vendored shUnit2 file has been modified from the upstream version.

_shunit_execSuite() {
  _shunit_timing_enabled="${SHUNIT2_TIMING:-false}"
  case "${_shunit_timing_enabled}" in
  true | TRUE | yes | YES | 1) _shunit_timing_enabled=true ;;
  *) _shunit_timing_enabled=false ;;
  esac
  _shunit_timing_records=''
  _shunit_timing_top="${SHUNIT2_TIMING_TOP:-20}"
  if ! echo "${_shunit_timing_top}" | grep -Eq '^[0-9]+$' ||
    command [ "${_shunit_timing_top}" -le 0 ]; then
    _shunit_timing_top=20
  fi

  for _shunit_test_ in ${__shunit_suite}; do
    if ${_shunit_timing_enabled}; then
      _shunit_test_start_epoch=$(date +%s)
    else
      _shunit_test_start_epoch=''
    fi
    __shunit_testSuccess=${SHUNIT_TRUE}

    # Disable skipping.
    endSkipping

    # Execute the per-test setup function.
    setUp
    command [ $? -eq ${SHUNIT_TRUE} ] ||
      _shunit_fatal "setup() returned non-zero return code."

    # Execute the test.
    echo "${__SHUNIT_TEST_PREFIX}${_shunit_test_}"
    # shunit2 dispatches test functions by name via eval as part of its harness.
    eval "${_shunit_test_}" # input-validation-audit: ignore
    if command [ $? -ne ${SHUNIT_TRUE} ]; then
      _shunit_error "${_shunit_test_}() returned non-zero return code."
      __shunit_testSuccess=${SHUNIT_ERROR}
      _shunit_incFailedCount
    fi

    # Execute the per-test tear-down function.
    tearDown
    command [ $? -eq ${SHUNIT_TRUE} ] ||
      _shunit_fatal "tearDown() returned non-zero return code."

    if ${_shunit_timing_enabled}; then
      _shunit_test_end_epoch=$(date +%s)
      _shunit_test_elapsed=$(expr "${_shunit_test_end_epoch}" - "${_shunit_test_start_epoch}")
      echo "[tests] elapsed ${_shunit_test_elapsed}s: ${_shunit_test_}"
      _shunit_timing_records="${_shunit_timing_records}${_shunit_test_elapsed} ${_shunit_test_}
"
    fi

    # Update stats.
    if command [ ${__shunit_testSuccess} -eq ${SHUNIT_TRUE} ]; then
      __shunit_testsPassed=$(expr ${__shunit_testsPassed} + 1)
    else
      __shunit_testsFailed=$(expr ${__shunit_testsFailed} + 1)
    fi
  done

  if ${_shunit_timing_enabled} && command [ -n "${_shunit_timing_records}" ]; then
    echo "[tests] Slowest ${_shunit_timing_top} shunit tests:"
    if ! _shunit_timing_file_=`mktemp "${TMPDIR:-/tmp}/dockistrate_shunit_timings.XXXXXX" 2>/dev/null`; then
      _shunit_warn 'unable to create timing summary temp file; skipping slowest-test summary.'
    elif ! printf '%s' "${_shunit_timing_records}" | sort -rn -k1,1 >"${_shunit_timing_file_}"; then
      _shunit_warn 'unable to sort timing summary; skipping slowest-test summary.'
      rm -f "${_shunit_timing_file_}"
    else
      _shunit_timing_printed_=0
      while read -r _shunit_timing_seconds_ _shunit_timing_name_; do
        command [ -n "${_shunit_timing_name_}" ] || continue
        echo "[tests] slow ${_shunit_timing_seconds_}s: ${_shunit_timing_name_}"
        _shunit_timing_printed_=`expr "${_shunit_timing_printed_}" + 1`
        command [ "${_shunit_timing_printed_}" -lt "${_shunit_timing_top}" ] || break
      done <"${_shunit_timing_file_}"
      rm -f "${_shunit_timing_file_}"
    fi
  fi

  unset _shunit_test_ _shunit_timing_enabled _shunit_timing_records
  unset _shunit_timing_top _shunit_test_start_epoch _shunit_test_end_epoch
  unset _shunit_test_elapsed _shunit_timing_seconds_ _shunit_timing_name_
  unset _shunit_timing_file_ _shunit_timing_printed_
}
