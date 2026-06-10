#!/usr/bin/env bash

test_update_security_ip_rejects_both_cidr() {
  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --scope both --ip 10.0.0.0/16) 2>&1)"
  status=$?

  assertTrue "update-security-ip should fail with both+cidr" "[ $status -ne 0 ]"
  assertStringContains "both cidr error" "[Error] CIDR values are not supported for ACL scope 'both': 10.0.0.0/16" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
