#!/usr/bin/env bash

test_acl_persisted_l3_cidr_rejected() {
  local output status rules_file

  run_dockistrate add-backend acl-persist-l3.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  rules_file="${CONFIG_DIR}/security_ip_rules.csv"
  cat >"$rules_file" <<EOF_RULE
enabled,domain,scope,action,ip_value,status_code
1,acl-persist-l3.test,l3,allow,10.9.0.0/16,
EOF_RULE

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on persisted l3 cidr acl" 0 "$status"
  assertStringContains "persisted l3 cidr context" "Invalid persisted ACL rule at line 2 for domain 'acl-persist-l3.test'" "$output"
  assertStringContains "persisted l3 cidr message" "CIDR values are not supported for ACL scope 'l3': 10.9.0.0/16" "$output"
}

test_acl_persisted_both_cidr_rejected() {
  local output status rules_file

  run_dockistrate add-backend acl-persist-both.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  rules_file="${CONFIG_DIR}/security_ip_rules.csv"
  cat >"$rules_file" <<EOF_RULE
enabled,domain,scope,action,ip_value,status_code
1,acl-persist-both.test,both,deny,10.9.0.0/16,451
EOF_RULE

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on persisted both cidr acl" 0 "$status"
  assertStringContains "persisted both cidr context" "Invalid persisted ACL rule at line 2 for domain 'acl-persist-both.test'" "$output"
  assertStringContains "persisted both cidr message" "CIDR values are not supported for ACL scope 'both': 10.9.0.0/16" "$output"
}
