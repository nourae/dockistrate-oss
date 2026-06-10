#!/usr/bin/env bash

test_acl_deny_non_403_trusted_proxies_do_not_bypass() {
  local acl_include rendered

  run_dockistrate add-backend acl-non403.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-acl acl-non403.test l7 allow 198.51.100.25 >/dev/null
  assertEquals "add-acl exact IP allow" 0 $?

  run_dockistrate set-trusted-proxies 192.0.2.10 >/dev/null
  assertEquals "set-trusted-proxies" 0 $?

  run_dockistrate set-acl-policy deny >/dev/null
  assertEquals "set-acl-policy deny" 0 $?

  run_dockistrate set-acl-status 451 >/dev/null
  assertEquals "set-acl-status 451" 0 $?

  acl_include="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/acl-non403.test.inc"
  assertTrue "non-403 deny policy should generate an ACL include" "[ -f \"$acl_include\" ]"
  rendered="$(cat "$acl_include")"
  assertStringContains "explicit exact-IP allow should still set the allow variable" \
    'if ($remote_addr = 198.51.100.25) { set $sr_' "$rendered"
  assertStringContains "non-403 deny policy should still emit the final return guard" \
    '_l7_allow = 0) { return 451; }' "$rendered"
  # shellcheck disable=SC1087
  assertFalse "trusted proxy exact IP should not set the allow variable" \
    "grep -Eq 'if \\(\\$remote_addr = 192\\.0\\.2\\.10\\) \\{ set \\$sr_[0-9]+_l7_allow 1; \\}' \"$acl_include\""
}
