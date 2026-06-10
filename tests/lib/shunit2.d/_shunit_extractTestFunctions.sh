#!/usr/bin/env bash

_shunit_extractTestFunctions() {
  _shunit_script_=$1

  # Extract the lines with test function names, strip of anything besides the
  # function name, and output everything on a single line.
  _shunit_regex_='^\s*((function test[A-Za-z0-9_-]*)|(test[A-Za-z0-9_-]* *\(\)))'
  # shellcheck disable=SC2196
  egrep "${_shunit_regex_}" "${_shunit_script_}" |
    command sed 's/^[^A-Za-z0-9_-]*//;s/^function //;s/\([A-Za-z0-9_-]*\).*/\1/g' |
    xargs

  unset _shunit_regex_ _shunit_script_
}
