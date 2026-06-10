#!/usr/bin/env bash

test_add_security_ip_rejects_both_cidr() {
  local output status
  output="$( (add_security_ip example.com both allow 10.0.0.0/16) 2>&1)"
  status=$?

  assertTrue "add-security-ip should fail with both+cidr" "[ $status -ne 0 ]"
  assertStringContains "both cidr error" "[Error] CIDR values are not supported for ACL scope 'both': 10.0.0.0/16" "$output"
  assertEquals "rules file should remain unchanged" "" "$(read_rules_file)"
}
