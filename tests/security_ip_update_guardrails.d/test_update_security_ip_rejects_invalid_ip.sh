#!/usr/bin/env bash

test_update_security_ip_rejects_invalid_ip() {
  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --ip not-an-ip) 2>&1)"
  status=$?

  assertTrue "update-security-ip should fail for invalid ip" "[ $status -ne 0 ]"
  assertStringContains "invalid ip error" "[Error] Invalid IP/CIDR 'not-an-ip'" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
