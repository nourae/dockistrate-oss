#!/usr/bin/env bash

test_security_rule_contains_literal_dot() {
  run_dockistrate add-backend literal-dot.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-security-rule literal-dot.test 1 path - contains a.b --code 418 >/dev/null
  assertEquals "add-security-rule" 0 $?

  local rules_file="${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  assertFileContainsSubstring '$host = literal-dot.test' "$rules_file"
  assertFileContainsSubstring '~* "a\.b"' "$rules_file"
  if grep -Fq '~* "a.b"' "$rules_file"; then
    fail "Expected dot to be escaped in regex literal, but found unescaped '~* "a.b"' in ${rules_file}"
  fi
}
