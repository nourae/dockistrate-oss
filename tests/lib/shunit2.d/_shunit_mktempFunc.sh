#!/usr/bin/env bash

_shunit_mktempFunc() {
  _shunit_stub_shebang='#! /bin/sh'

  for _shunit_func_ in oneTimeSetUp oneTimeTearDown setUp tearDown suite noexec; do
    _shunit_file_="${__shunit_tmpDir}/${_shunit_func_}"
    command cat <<EOF >"${_shunit_file_}"
${_shunit_stub_shebang}
exit ${SHUNIT_TRUE}
EOF
    command chmod +x "${_shunit_file_}"
  done

  unset _shunit_file_ _shunit_func_ _shunit_stub_shebang
}
