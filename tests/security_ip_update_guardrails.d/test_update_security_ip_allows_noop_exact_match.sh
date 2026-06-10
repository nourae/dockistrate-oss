#!/usr/bin/env bash

test_update_security_ip_allows_noop_exact_match() {
  local before output status
  before="$(read_rules_file)"
  output="$(update_security_ip 1 --domain example.com --scope l7 --action allow --ip 192.0.2.10 --code 200 2>&1)"
  status=$?

  assertEquals "noop update-security-ip should succeed" 0 "$status"
  assertStringContains "update output" "Updated security IP rule 1" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
