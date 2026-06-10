#!/usr/bin/env bash

test_update_security_ip_rejects_invalid_scope() {
  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --scope bogus) 2>&1)"
  status=$?

  assertTrue "update-security-ip should fail for invalid scope" "[ $status -ne 0 ]"
  assertStringContains "invalid scope message" "Invalid scope 'bogus'" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
