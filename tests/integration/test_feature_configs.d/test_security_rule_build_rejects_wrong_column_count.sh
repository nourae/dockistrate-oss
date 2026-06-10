#!/usr/bin/env bash

test_security_rule_build_rejects_wrong_column_count() {
  local output status rules_file

  run_dockistrate add-backend sec-colcount-build.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  rules_file="${CONFIG_DIR}/security_rules.csv"
  cat >"$rules_file" <<EOF_RULE
enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location
1,sec-colcount-build.test,single,499,1,ip,l7,equals,10.0.0.1
EOF_RULE

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on wrong security rule column count" 0 "$status"
  assertStringContains "invalid persisted column-count context" "Invalid persisted security rule column count in ${rules_file} at line 2: expected 47, got 9" "$output"
}
