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

test_add_security_ip_rejects_duplicate_exact_match_in_one_request() {
  local output status rules line_count

  output="$( (add_security_ip example.com l7 allow 192.0.2.51 192.0.2.51) 2>&1)"
  status=$?
  assertTrue "same-request duplicate add-security-ip should fail" "[ $status -ne 0 ]"
  assertStringContains "same-request duplicate acl error" "[Error] ACL rule already exists for example.com: scope=l7 action=allow ip=192.0.2.51" "$output"

  rules="$(read_rules_file)"
  line_count="$(printf '%s\n' "$rules" | sed '/^$/d' | wc -l | tr -d ' ')"
  assertEquals "same-request duplicate should not add acl rows" "0" "$line_count"
}

test_add_security_ip_rejects_duplicate_exact_match_in_space_list() {
  local output status rules line_count

  output="$( (add_security_ip example.com l7 allow '192.0.2.52 192.0.2.52') 2>&1)"
  status=$?
  assertTrue "space-list duplicate add-security-ip should fail" "[ $status -ne 0 ]"
  assertStringContains "space-list duplicate acl error" "[Error] ACL rule already exists for example.com: scope=l7 action=allow ip=192.0.2.52" "$output"

  rules="$(read_rules_file)"
  line_count="$(printf '%s\n' "$rules" | sed '/^$/d' | wc -l | tr -d ' ')"
  assertEquals "space-list duplicate should not add acl rows" "0" "$line_count"
}

test_add_security_ip_allows_distinct_values_in_one_request() {
  local output status rules line_count

  output="$(add_security_ip example.com l7 allow 192.0.2.53 192.0.2.54 2>&1)"
  status=$?
  assertEquals "distinct values should succeed" 0 "$status"

  rules="$(read_rules_file)"
  line_count="$(printf '%s\n' "$rules" | sed '/^$/d' | wc -l | tr -d ' ')"
  assertEquals "distinct values should add two acl rows" "2" "$line_count"
  assertEquals "distinct values should preserve request order" "example.com,l7,allow,192.0.2.53
example.com,l7,allow,192.0.2.54" "$rules"
}
