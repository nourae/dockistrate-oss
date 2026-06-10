#!/usr/bin/env bash

_shunit_assertPass() {
  __shunit_assertsPassed=$(expr ${__shunit_assertsPassed} + 1)
  __shunit_assertsTotal=$(expr ${__shunit_assertsTotal} + 1)
}
