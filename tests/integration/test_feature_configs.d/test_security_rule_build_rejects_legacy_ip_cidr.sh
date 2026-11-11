#!/usr/bin/env bash

test_security_rule_build_rejects_legacy_ip_cidr() {
  local output status rules_file

  run_dockistrate add-backend sec-cidr-build.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  rules_file="${STATE_DIR}/domains/sec-cidr-build.test/runtime/applied/security_rules.csv"
  printf 'rule_id,order,enabled,action,mode,status_code,reason,source_location\nrule-invalid,1,1,require,single,499,-,auto\n' >"$rules_file"
  printf 'rule_id,condition_order,selector,name,operator,value\nrule-invalid,1,ip,l7,equals,10.0.0.0/8\n' >"${rules_file%/*}/security_conditions.csv"

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on persisted invalid cidr rule" 0 "$status"
  assertStringContains "invalid persisted rule context" "security_conditions.csv" "$output"
}
