#!/usr/bin/env bash

_shunit_assertSkip() {
  __shunit_assertsSkipped=$(expr "${__shunit_assertsSkipped}" + 1)
  __shunit_assertsTotal=$(expr "${__shunit_assertsTotal}" + 1)
}
