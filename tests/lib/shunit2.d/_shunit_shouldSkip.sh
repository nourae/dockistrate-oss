#!/usr/bin/env bash

_shunit_shouldSkip() {
  command [ ${__shunit_skip} -eq ${SHUNIT_FALSE} ] && return ${SHUNIT_FALSE}
  _shunit_assertSkip
}
