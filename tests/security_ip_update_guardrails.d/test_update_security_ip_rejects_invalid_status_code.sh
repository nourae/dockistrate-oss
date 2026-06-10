#!/usr/bin/env bash

test_update_security_ip_rejects_invalid_status_code() {
  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --code 99) 2>&1)"
  status=$?

  assertTrue "update-security-ip should fail for invalid status code" "[ $status -ne 0 ]"
  assertStringContains "invalid status code message" "[Error] Invalid status code: 99" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
