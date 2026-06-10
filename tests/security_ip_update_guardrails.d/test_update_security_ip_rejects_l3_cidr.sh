#!/usr/bin/env bash

test_update_security_ip_rejects_l3_cidr() {
  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --scope l3 --ip 10.0.0.0/16) 2>&1)"
  status=$?

  assertTrue "update-security-ip should fail for l3 cidr" "[ $status -ne 0 ]"
  assertStringContains "l3 cidr error" "[Error] CIDR values are not supported for ACL scope 'l3': 10.0.0.0/16" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
