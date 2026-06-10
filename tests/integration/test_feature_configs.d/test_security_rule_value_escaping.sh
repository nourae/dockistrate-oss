#!/usr/bin/env bash

test_security_rule_value_escaping() {
  run_dockistrate add-backend quote-rule.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-security-rule quote-rule.test 1 header User-Agent equals 'Foo "Bar"/Baz' >/dev/null
  assertEquals "add-security-rule" 0 $?

  local rules_file="${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  assertFileContainsSubstring 'Foo \"Bar\"/Baz' "$rules_file"
}
