#!/usr/bin/env bash

test_security_and_acl_rules_emit_expected_includes() {
  run_dockistrate add-backend policy.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-port policy.test 9000 18180 tcp none >/dev/null
  assertEquals "add-port tcp" 0 $?

  run_dockistrate add-acl policy.test l7 allow 10.1.0.0/16 200 >/dev/null
  assertEquals "add-acl l7" 0 $?

  run_dockistrate add-acl policy.test l3 deny 192.168.0.10 451 >/dev/null
  assertEquals "add-acl l3" 0 $?

  run_dockistrate add-acl policy.test both allow 172.16.0.5 >/dev/null
  assertEquals "add-acl both" 0 $?

  run_dockistrate set-trusted-proxies 10.0.0.0/8 >/dev/null
  assertEquals "set-trusted-proxies" 0 $?

  local output
  output="$(run_dockistrate add-acl policy.test both allow 10.2.0.0/16)"
  assertNotEquals "add-acl both cidr should fail" 0 $?
  assertStringContains "both cidr guardrail message" "CIDR values are not supported for ACL scope 'both'" "$output"

  run_dockistrate add-security-rule policy.test 1 header X-Block equals disallowed --code 429 >/dev/null
  assertEquals "add-security-rule" 0 $?

  assertFileContains "1,policy.test,l7,allow,10.1.0.0/16,200" "${CONFIG_DIR}/security_ip_rules.csv"
  assertFileContains "1,policy.test,l3,deny,192.168.0.10,451" "${CONFIG_DIR}/security_ip_rules.csv"
  assertFileContains "1,policy.test,both,allow,172.16.0.5," "${CONFIG_DIR}/security_ip_rules.csv"
  assertFalse "both+cidr should not be stored" "grep -Fq 'policy.test,both,allow,10.2.0.0/16' \"${CONFIG_DIR}/security_ip_rules.csv\""
  assertFileContainsSubstring 'allow 10.1.0.0/16;' "${CONFIG_DIR}/nginx_conf/conf.d/security_ip/policy.test.inc"
  assertFileContainsSubstring 'allow 172.16.0.5;' "${CONFIG_DIR}/nginx_conf/conf.d/security_ip/policy.test.inc"
  assertFalse "trusted proxies should not bypass HTTP deny policy" \
    "grep -Fq 'allow 10.0.0.0/8;' \"${CONFIG_DIR}/nginx_conf/conf.d/security_ip/policy.test.inc\""
  assertFileContainsSubstring 'if ($realip_remote_addr = 192.168.0.10) { return 451; }' "${CONFIG_DIR}/nginx_conf/conf.d/security_ip/policy.test.inc"
  assertFileContainsSubstring 'realip_remote_addr = 172.16.0.5' "${CONFIG_DIR}/nginx_conf/conf.d/security_ip/policy.test.inc"
  assertFalse "rejected cidr should not generate L3 match" "grep -q 'realip_remote_addr = 10.2.0.0/16' \"${CONFIG_DIR}/nginx_conf/conf.d/security_ip/policy.test.inc\""
  assertFileContainsSubstring 'include /etc/nginx/dockistrate/stream_conf/security_ip/policy.test.inc;' "${CONFIG_DIR}/nginx_conf/stream_conf/streams.conf"
  assertFileContainsSubstring 'allow 10.1.0.0/16;' "${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/policy.test.inc"
  assertFileContainsSubstring 'allow 172.16.0.5;' "${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/policy.test.inc"
  assertFalse "trusted proxies should not bypass stream deny policy" \
    "grep -Fq 'allow 10.0.0.0/8;' \"${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/policy.test.inc\""
  assertFileContainsSubstring 'deny 192.168.0.10;' "${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/policy.test.inc"
  assertFileContainsSubstring 'deny all;' "${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/policy.test.inc"
  assertFileContainsSubstring '$host = policy.test' "${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  assertFileContainsSubstring 'return 429;' "${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
}
