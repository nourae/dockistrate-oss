#!/usr/bin/env bash

test_add_security_ip_rejects_empty_space_list_without_unbound_failure() {
  local before output status
  before="$(read_rules_file)"
  output="$( (add_security_ip example.com l7 allow '   ') 2>&1)"
  status=$?

  assertTrue "add-security-ip should reject an empty space-separated list" "[ $status -ne 0 ]"
  assertStringContains "empty ACL list error" "[Error] Invalid IP/CIDR" "$output"
  assertFalse "empty ACL list should not hit Bash 3 unbound variable" \
    "[[ \"$output\" == *\"unbound variable\"* ]]"
  assertEquals "empty ACL list should not change state" "$before" "$(read_rules_file)"
}
