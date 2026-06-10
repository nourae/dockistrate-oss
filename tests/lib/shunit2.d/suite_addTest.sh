#!/usr/bin/env bash

suite_addTest() {
  shunit_func_=${1:-}

  __shunit_suite="${__shunit_suite:+${__shunit_suite} }${shunit_func_}"
  __shunit_testsTotal=$(expr ${__shunit_testsTotal} + 1)

  unset shunit_func_
}
