#!/usr/bin/env bash

# shellcheck source=lib/utils/csv.sh
source "${ROOT_DIR}/lib/utils/csv.sh"

test_security_rule_rejects_injection_values() {
  run_dockistrate add-backend injection-rule.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  # Test newline injection attempt
  local output status
  output="$(run_dockistrate add-security-rule injection-rule.test 1 header User-Agent matches 'bad
value' 2>&1)"
  status=$?
  assertNotEquals "add-security-rule should reject newlines" 0 $status
  assertStringContains "error should mention control characters" "control characters" "$output"

  # Test delimiters are allowed when properly quoted/escaped
  output="$(run_dockistrate add-security-rule injection-rule.test 1 header User-Agent equals 'semi;brace{ok}' 2>&1)"
  status=$?
  assertEquals "add-security-rule should allow delimiters" 0 $status

  # Test valid value is accepted
  output="$(run_dockistrate add-security-rule injection-rule.test 1 header User-Agent equals 'normalvalue' 2>&1)"
  status=$?
  assertEquals "add-security-rule should accept normal value" 0 $status

  # Test update-security-rule also validates
  local rules_file="${CONFIG_DIR}/security_rules.csv"
  local rule_id="" line="" line_no=0 row_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    row_no=$((row_no + 1))
    if [ "${CSV_FIELDS[1]-}" = "injection-rule.test" ]; then
      rule_id="$row_no"
      break
    fi
  done <"$rules_file"
  if [ -z "$rule_id" ]; then
    fail "Expected security rule entry for injection-rule.test in ${rules_file}"
    return
  fi

  output="$(run_dockistrate update-security-rule "$rule_id" --count 1 header User-Agent equals 'bad
update' 2>&1)"
  status=$?
  assertNotEquals "update-security-rule should reject newlines" 0 $status
}
