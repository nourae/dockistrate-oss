#!/usr/bin/env bash

# shellcheck source=lib/utils/csv.sh
source "${ROOT_DIR}/lib/utils/csv.sh"

test_security_rule_rejects_invalid_code() {
  run_dockistrate add-backend invalid-rule-code.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-security-rule invalid-rule-code.test 1 header User-Agent equals ok --code 99 >/dev/null 2>&1
  assertNotEquals "add-security-rule invalid code" 0 $?

  run_dockistrate add-security-rule invalid-rule-code.test 1 header User-Agent equals ok --code 401 >/dev/null
  assertEquals "add-security-rule valid code" 0 $?

  local rules_file="${CONFIG_DIR}/security_rules.csv"
  local rule_id="" line="" line_no=0 row_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    row_no=$((row_no + 1))
    if [ "${CSV_FIELDS[1]-}" = "invalid-rule-code.test" ]; then
      rule_id="$row_no"
      break
    fi
  done <"$rules_file"
  if [ -z "$rule_id" ]; then
    fail "Expected security rule entry for invalid-rule-code.test in ${rules_file}"
  fi

  run_dockistrate update-security-rule "$rule_id" --code 99 >/dev/null 2>&1
  assertNotEquals "update-security-rule invalid code" 0 $?
}
