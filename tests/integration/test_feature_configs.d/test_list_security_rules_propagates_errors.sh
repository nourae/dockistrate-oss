#!/usr/bin/env bash

test_list_security_rules_fails_on_corrupt_state() {
  local output status domain="list-corrupt.test" draft_before

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed applied backend for corrupt-list state" 0 $?
  draft_before="$(cat "${STATE_DIR}/domains/${domain}/config/security_rules.csv")"

  # A cache-only edit is repaired from applied configuration. Corrupt the
  # accepted snapshot too, so listing must inspect the invalid fallback cache.
  # The editable draft remains valid and must not participate in this failure.
  printf '%s\n' "not_the_security_rules_header" >"${STATE_DIR}/domains/${domain}/runtime/applied/security_rules.csv"
  printf '%s\n' "not_the_security_rules_header" >"${CONFIG_DIR}/security_rules.csv"

  output="$(run_dockistrate list-security-rules 2>&1)"
  status=$?

  assertNotEquals "list-security-rules should fail on corrupt persisted state" 0 "$status"
  assertStringContains "list-security-rules should report invalid header" "Invalid header" "$output"
  assertTrue "list-security-rules should not mask the failure as empty state" \
    "[[ \"$output\" != *\"No security rules configured\"* ]]"

  assertEquals "listing corrupt applied state preserves the valid editable draft" \
    "$draft_before" "$(cat "${STATE_DIR}/domains/${domain}/config/security_rules.csv")"
}
