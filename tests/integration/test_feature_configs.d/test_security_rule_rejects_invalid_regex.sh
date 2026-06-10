#!/usr/bin/env bash

function _security_rule_has_regex_validator() {
  local grep_status=0

  if command -v pcre2grep >/dev/null 2>&1; then
    return 0
  fi

  printf '' | grep -P '' >/dev/null 2>&1
  grep_status=$?
  if [ "$grep_status" -eq 0 ] || [ "$grep_status" -eq 1 ]; then
    return 0
  fi

  return 1
}

test_security_rule_rejects_invalid_regex() {
  if ! _security_rule_has_regex_validator; then
    startSkipping
    assertTrue "skip invalid-regex rejection assertions when no compatible validator is available" 0
    endSkipping
    return 0
  fi

  run_dockistrate add-backend invalid-regex.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  local output status
  output="$(run_dockistrate add-security-rule invalid-regex.test 1 header User-Agent matches '([A-Z' 2>&1)"
  status=$?
  assertNotEquals "add-security-rule should reject invalid regex" 0 "$status"
  assertStringContains "invalid regex add error" "Invalid security rule for domain 'invalid-regex.test': invalid regex pattern: ([A-Z" "$output"

  run_dockistrate add-security-rule invalid-regex.test 1 header User-Agent matches '^[A-Z]+$' --code 451 >/dev/null
  assertEquals "seed valid regex rule" 0 $?

  output="$(run_dockistrate update-security-rule 1 --count 1 header User-Agent matches '([0-9' 2>&1)"
  status=$?
  assertNotEquals "update-security-rule should reject invalid regex" 0 "$status"
  assertStringContains "invalid regex update error" "Invalid security rule update for domain 'invalid-regex.test': invalid regex pattern: ([0-9" "$output"
}
