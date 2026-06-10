#!/usr/bin/env bash

test_list_security_rules_fails_on_corrupt_state() {
  local output status

  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "not_the_security_rules_header" >"${CONFIG_DIR}/security_rules.csv"

  output="$(run_dockistrate list-security-rules 2>&1)"
  status=$?

  assertNotEquals "list-security-rules should fail on corrupt persisted state" 0 "$status"
  assertStringContains "list-security-rules should report invalid header" "Invalid header" "$output"
  assertTrue "list-security-rules should not mask the failure as empty state" \
    "[[ \"$output\" != *\"No security rules configured\"* ]]"

  printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"${CONFIG_DIR}/security_rules.csv"
}
