#!/usr/bin/env bash

test_l3_policy_deny_without_rows_enforced() {
  run_dockistrate add-backend l3-default-deny.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate set-backend-acl-policy l3-default-deny.test deny >/dev/null
  assertEquals "set-backend-acl-policy deny" 0 $?

  local include_file="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/l3-default-deny.test.inc"
  assertTrue "security ip include exists" "[ -f \"$include_file\" ]"
  assertTrue "L3 deny fallback variable emitted" "grep -Eq '_l3_allow 0;' \"$include_file\""
  assertTrue "L3 deny fallback return emitted" "grep -Eq '_l3_allow = 0\\) \\{ return 403; \\}' \"$include_file\""
}
