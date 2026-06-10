#!/usr/bin/env bash

test_security_rule_cookie_arg_hyphen_names() {
  run_dockistrate add-backend hyphen-rule.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-security-rule hyphen-rule.test 2 cookie session-id equals abc arg token-id equals xyz --mode and >/dev/null
  assertEquals "add-security-rule" 0 $?

  local rules_file="${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  assertFileContainsSubstring '$cookie_session_id' "$rules_file"
  assertFileContainsSubstring '$arg_token_id' "$rules_file"
}
