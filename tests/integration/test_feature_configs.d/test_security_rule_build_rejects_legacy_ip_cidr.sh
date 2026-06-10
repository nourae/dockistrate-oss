#!/usr/bin/env bash

test_security_rule_build_rejects_legacy_ip_cidr() {
  local output status rules_file

  run_dockistrate add-backend sec-cidr-build.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  rules_file="${CONFIG_DIR}/security_rules.csv"
  local malformed_row
  malformed_row="1,sec-cidr-build.test,single,499,1,ip,l7,equals,10.0.0.0/8"
  for _i in $(seq 1 38); do
    malformed_row="${malformed_row},"
  done
  cat >"$rules_file" <<EOF_RULE
enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location
${malformed_row}
EOF_RULE

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on persisted invalid cidr rule" 0 "$status"
  assertStringContains "invalid persisted rule context" "Invalid persisted security rule #1 for domain 'sec-cidr-build.test'" "$output"
}
