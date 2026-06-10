#!/usr/bin/env bash

test_security_rule_rejects_empty_fields() {
  run_dockistrate add-backend empty-fields-rule.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  local output status

  output="$(run_dockistrate add-security-rule empty-fields-rule.test 1 '' - equals ok 2>&1)"
  status=$?
  assertNotEquals "add-security-rule should reject empty source" 0 "$status"
  assertStringContains "empty source error should be explicit" "source cannot be empty" "$output"
  assertTrue "empty source failure should stay controlled" "[[ \"$output\" != *\"unbound variable\"* ]]"

  output="$(run_dockistrate add-security-rule empty-fields-rule.test 1 header - equals ok 2>&1)"
  status=$?
  assertNotEquals "add-security-rule should reject empty header name" 0 "$status"
  assertStringContains "empty header name error should be explicit" "requires a non-empty name" "$output"

  output="$(run_dockistrate add-security-rule empty-fields-rule.test 1 header User-Agent equals '' 2>&1)"
  status=$?
  assertNotEquals "add-security-rule should reject empty value for equals" 0 "$status"
  assertStringContains "empty value error should be explicit" "value cannot be empty" "$output"

  output="$(run_dockistrate add-security-rule empty-fields-rule.test 1 header User-Agent exists - 2>&1)"
  status=$?
  assertEquals "add-security-rule should allow placeholder value for exists" 0 "$status"

  output="$(run_dockistrate update-security-rule 1 --count 1 header - equals ok 2>&1)"
  status=$?
  assertNotEquals "update-security-rule should reject empty header name" 0 "$status"
  assertStringContains "update empty header name error should be explicit" "requires a non-empty name" "$output"

  output="$(run_dockistrate update-security-rule 1 --count 1 '' - equals ok 2>&1)"
  status=$?
  assertNotEquals "update-security-rule should reject empty source" 0 "$status"
  assertStringContains "update empty source error should be explicit" "source cannot be empty" "$output"
  assertTrue "update empty source failure should stay controlled" "[[ \"$output\" != *\"unbound variable\"* ]]"

  output="$(run_dockistrate update-security-rule 1 --count 1 header User-Agent equals '' 2>&1)"
  status=$?
  assertNotEquals "update-security-rule should reject empty value for equals" 0 "$status"
  assertStringContains "update empty value error should be explicit" "value cannot be empty" "$output"

  output="$(run_dockistrate update-security-rule 1 --count 1 header User-Agent exists - 2>&1)"
  status=$?
  assertEquals "update-security-rule should allow placeholder value for exists" 0 "$status"
}
