#!/usr/bin/env bash

_shunit_incFailedCount() {
  __shunit_assertsFailed=$(expr "${__shunit_assertsFailed}" + 1)
  __shunit_assertsTotal=$(expr "${__shunit_assertsTotal}" + 1)
}
