#!/usr/bin/env bash

test_update_security_ip_rejects_invalid_action() {
  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --action maybe) 2>&1)"
  status=$?

  assertTrue "update-security-ip should fail for invalid action" "[ $status -ne 0 ]"
  assertStringContains "invalid action message" "Invalid action 'maybe'" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
