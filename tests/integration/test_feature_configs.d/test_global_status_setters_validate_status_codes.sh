#!/usr/bin/env bash

test_global_status_setters_validate_status_codes() {
  local output status

  output="$(run_dockistrate set-security-rule-status 451)"
  status=$?
  assertEquals "set-security-rule-status should accept valid codes" 0 "$status"

  output="$(run_dockistrate set-acl-status 498)"
  status=$?
  assertEquals "set-acl-status should accept valid codes" 0 "$status"

  output="$(run_dockistrate set-security-rule-status 99)"
  status=$?
  assertTrue "set-security-rule-status should reject codes below 100" "[ ${status} -ne 0 ]"
  assertStringContains "set-security-rule-status low-code error" "[Error] Invalid status code" "$output"

  output="$(run_dockistrate set-security-rule-status 600)"
  status=$?
  assertTrue "set-security-rule-status should reject codes above 599" "[ ${status} -ne 0 ]"
  assertStringContains "set-security-rule-status high-code error" "expected 100-599" "$output"

  output="$(run_dockistrate set-acl-status 42)"
  status=$?
  assertTrue "set-acl-status should reject codes below 100" "[ ${status} -ne 0 ]"
  assertStringContains "set-acl-status low-code error" "[Error] Invalid status code" "$output"

  output="$(run_dockistrate set-acl-status 777)"
  status=$?
  assertTrue "set-acl-status should reject codes above 599" "[ ${status} -ne 0 ]"
  assertStringContains "set-acl-status high-code error" "expected 100-599" "$output"
}
