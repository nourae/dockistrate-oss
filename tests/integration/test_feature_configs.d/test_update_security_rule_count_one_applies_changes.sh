#!/usr/bin/env bash

# shellcheck source=lib/utils/csv.sh
source "${ROOT_DIR}/lib/utils/csv.sh"

test_update_security_rule_count_one_applies_changes() {
  run_dockistrate add-backend update-rule.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  run_dockistrate add-security-rule update-rule.test 1 header X-Guard equals initial --code 431 >/dev/null
  assertEquals "seed security rule" 0 $?

  local rules_file rule_id
  rules_file="${CONFIG_DIR}/security_rules.csv"
  rule_id=""
  local line="" line_no=0 row_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    row_no=$((row_no + 1))
    if [ "${CSV_FIELDS[1]-}" = "update-rule.test" ]; then
      rule_id="$row_no"
      break
    fi
  done <"$rules_file"
  if [ -z "$rule_id" ]; then
    fail "Expected a security rule row for update-rule.test in ${rules_file}"
    return
  fi

  local output
  output="$(run_dockistrate update-security-rule "$rule_id" --domain update-rule.test --count 1 header X-Guard equals final --code 432 2>&1)"
  assertEquals "update-security-rule --count 1 should succeed" 0 $?
  assertStringContains "update output" "Updated rule $rule_id" "$output"

  local listed
  listed="$(run_dockistrate list-security-rules update-rule.test)"
  assertEquals "list-security-rules should succeed" 0 $?
  assertStringContains "rule should show updated value" "header:X-Guard equals final" "$listed"
  assertStringContains "rule should show updated status" "status=432" "$listed"
}
