#!/usr/bin/env bash

test_security_rule_build_rejects_malformed_row() {
  local output status rules_file

  run_dockistrate add-backend sec-malformed-build.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  rules_file="${STATE_DIR}/domains/sec-malformed-build.test/runtime/applied/security_rules.csv"
  cat >"$rules_file" <<EOF_RULE
rule_id,order,enabled,action,mode,status_code,reason,source_location
rule-invalid,1,1,require,single,499,"unterminated
EOF_RULE

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on malformed persisted security rule row" 0 "$status"
  assertStringContains "invalid persisted row context" "unterminated quoted field" "$output"
}
