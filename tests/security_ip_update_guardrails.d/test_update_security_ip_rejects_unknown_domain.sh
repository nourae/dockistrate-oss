#!/usr/bin/env bash

test_update_security_ip_rejects_unknown_domain() {
  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --domain unknown.test) 2>&1)"
  status=$?

  assertTrue "update-security-ip should fail for unknown domain" "[ $status -ne 0 ]"
  assertStringContains "unknown domain error" "[Error] Unknown domain 'unknown.test'" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
