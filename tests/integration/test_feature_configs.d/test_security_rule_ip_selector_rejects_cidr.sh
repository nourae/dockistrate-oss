#!/usr/bin/env bash

test_security_rule_ip_selector_rejects_cidr() {
  local output status

  run_dockistrate add-backend sec-cidr.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  output="$(run_dockistrate add-security-rule sec-cidr.test 1 ip l7 equals 10.0.0.0/8 --code 499)"
  status=$?
  assertNotEquals "add-security-rule should reject cidr with equals" 0 "$status"
  assertStringContains "equals cidr rejection message" "CIDR values are not supported for 'ip:l7' with condition 'equals'" "$output"

  output="$(run_dockistrate add-security-rule sec-cidr.test 1 ip l3 in 172.19.0.1,10.0.0.0/8 --code 499)"
  status=$?
  assertNotEquals "add-security-rule should reject cidr in list" 0 "$status"
  assertStringContains "list cidr rejection message" "CIDR values are not supported for 'ip:l3' with condition 'in'" "$output"

  run_dockistrate add-security-rule sec-cidr.test 1 ip l3 equals 172.19.0.1 --code 499 >/dev/null
  assertEquals "add-security-rule exact ip should succeed" 0 $?

  output="$(run_dockistrate update-security-rule 1 --count 1 ip l3 equals 10.0.0.0/8 --code 499)"
  status=$?
  assertNotEquals "update-security-rule should reject cidr with equals" 0 "$status"
  assertStringContains "update cidr rejection message" "CIDR values are not supported for 'ip:l3' with condition 'equals'" "$output"
}
