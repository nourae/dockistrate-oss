#!/usr/bin/env bash

test_security_rule_condition_polarity() {
  run_dockistrate add-backend polarity-rule.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 header X-Eq equals secret --code 401 >/dev/null
  assertEquals "add-security-rule equals" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 header X-Neq not_equals secret --code 402 >/dev/null
  assertEquals "add-security-rule not_equals" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 path - starts_with /admin --code 405 >/dev/null
  assertEquals "add-security-rule starts_with" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 uri - ends_with .json --code 407 >/dev/null
  assertEquals "add-security-rule ends_with" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 header X-Match matches '(curl|wget)' --code 409 >/dev/null
  assertEquals "add-security-rule matches" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 method - in GET,POST --code 410 >/dev/null
  assertEquals "add-security-rule in" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 header X-NotIn not_in 'alpha|beta' --code 411 >/dev/null
  assertEquals "add-security-rule not_in" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 var request_length gt 100 --code 412 >/dev/null
  assertEquals "add-security-rule gt" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 header X-Exists exists - --code 413 >/dev/null
  assertEquals "add-security-rule exists" 0 $?

  run_dockistrate add-security-rule polarity-rule.test 1 header X-Missing not_exists - --code 414 >/dev/null
  assertEquals "add-security-rule not_exists" 0 $?

  local rules_file="${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  assertFileContainsSubstring '$host = polarity-rule.test' "$rules_file"
  assertFileContainsSubstring '$http_x_eq = "secret"' "$rules_file"
  assertFileContainsSubstring '$http_x_neq != "secret"' "$rules_file"
  assertFileContainsSubstring '$uri ~* "^\/admin"' "$rules_file"
  assertFileContainsSubstring '$request_uri ~* "\.json$"' "$rules_file"
  assertFileContainsSubstring '$http_x_match ~* "((curl|wget))"' "$rules_file"
  assertFileContainsSubstring '$request_method ~* "^(?:GET|POST)$"' "$rules_file"
  assertFileContainsSubstring '$http_x_notin !~* "^(?:alpha|beta)$"' "$rules_file"
  assertFileContainsSubstring '$request_length ~* "^' "$rules_file"
  assertFileContainsSubstring '$http_x_exists != ""' "$rules_file"
  assertFileContainsSubstring '$http_x_missing = ""' "$rules_file"
}
