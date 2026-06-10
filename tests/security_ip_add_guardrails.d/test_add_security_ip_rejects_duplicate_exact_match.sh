#!/usr/bin/env bash

test_add_security_ip_rejects_duplicate_exact_match() {
  local output status rules line_count

  output="$(add_security_ip example.com l7 allow 192.0.2.50 2>&1)"
  status=$?
  assertEquals "first add-security-ip should succeed" 0 "$status"

  output="$( (add_security_ip example.com l7 allow 192.0.2.50) 2>&1)"
  status=$?
  assertTrue "duplicate add-security-ip should fail" "[ $status -ne 0 ]"
  assertStringContains "duplicate acl error" "[Error] ACL rule already exists for example.com: scope=l7 action=allow ip=192.0.2.50" "$output"

  rules="$(read_rules_file)"
  line_count="$(printf '%s\n' "$rules" | sed '/^$/d' | wc -l | tr -d ' ')"
  assertEquals "rules file should keep a single acl row" "1" "$line_count"
  assertEquals "rules file should keep the original row" "example.com,l7,allow,192.0.2.50" "$rules"
}
