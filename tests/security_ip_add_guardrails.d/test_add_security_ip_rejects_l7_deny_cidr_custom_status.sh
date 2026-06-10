#!/usr/bin/env bash

test_add_security_ip_rejects_l7_deny_cidr_custom_status() {
  local before output status
  before="$(read_rules_file)"
  output="$( (add_security_ip example.com l7 deny 0.0.0.0/0 418) 2>&1)"
  status=$?

  assertTrue "add-security-ip should fail for l7 deny cidr with custom status" "[ $status -ne 0 ]"
  assertStringContains "l7 cidr custom status error" "[Error] CIDR L7 deny rules always return 403; use status 403 or an exact IP for custom status: 0.0.0.0/0" "$output"
  assertEquals "rules file should remain unchanged" "$before" "$(read_rules_file)"
}

test_add_security_ip_allows_l7_deny_cidr_403() {
  local output status
  output="$(add_security_ip example.com l7 deny 0.0.0.0/0 403 2>&1)"
  status=$?

  assertEquals "add-security-ip should allow l7 deny cidr with 403" 0 "$status"
  assertEquals "rules file should contain cidr deny with 403" "example.com,l7,deny,0.0.0.0/0,403" "$(read_rules_file)"
}

test_add_security_ip_allows_l7_deny_exact_ip_custom_status() {
  local output status
  output="$(add_security_ip example.com l7 deny 192.0.2.10 418 2>&1)"
  status=$?

  assertEquals "add-security-ip should allow l7 deny exact ip with custom status" 0 "$status"
  assertEquals "rules file should contain exact ip deny with custom status" "example.com,l7,deny,192.0.2.10,418" "$(read_rules_file)"
}
