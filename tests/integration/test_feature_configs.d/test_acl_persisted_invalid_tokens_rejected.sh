#!/usr/bin/env bash

test_acl_persisted_l7_injection_rejected() {
  local domain="acl-persist-l7-inject.test"
  local rules_file http_include before_http after_http output status

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  rules_file="${CONFIG_DIR}/security_ip_rules.csv"
  http_include="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/${domain}.inc"
  before_http="$(cat "$http_include")"

  cat >"$rules_file" <<EOF_RULE
enabled,domain,scope,action,ip_value,status_code
1,${domain},l7,deny,1.2.3.4; return 200;,403
EOF_RULE

  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail on injected persisted l7 acl" 0 "$status"
  assertStringContains "persisted l7 injection context" "Invalid persisted ACL rule at line 2 for domain '${domain}'" "$output"
  assertStringContains "persisted l7 injection reason" "Invalid IP/CIDR for ACL scope 'l7' action 'deny': 1.2.3.4; return 200;" "$output"

  after_http="$(cat "$http_include")"
  assertEquals "http acl include should be rolled back after invalid persisted l7 acl" "$before_http" "$after_http"
}

test_acl_persisted_stream_deny_injection_rejected() {
  local domain="acl-persist-stream-inject.test"
  local rules_file stream_include before_stream after_stream output status

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?
  run_dockistrate add-port "$domain" 9000 18180 tcp none >/dev/null
  assertEquals "seed tcp port" 0 $?

  rules_file="${CONFIG_DIR}/security_ip_rules.csv"
  stream_include="${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/${domain}.inc"
  before_stream="$(cat "$stream_include")"

  cat >"$rules_file" <<EOF_RULE
enabled,domain,scope,action,ip_value,status_code
1,${domain},l7,deny,1.2.3.4; return 200;,403
EOF_RULE

  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail on injected persisted stream acl" 0 "$status"
  assertStringContains "persisted stream injection context" "Invalid persisted ACL rule at line 2 for domain '${domain}'" "$output"
  assertStringContains "persisted stream injection reason" "Invalid IP/CIDR for ACL scope 'l7' action 'deny': 1.2.3.4; return 200;" "$output"

  after_stream="$(cat "$stream_include")"
  assertEquals "stream acl include should be rolled back after invalid persisted acl" "$before_stream" "$after_stream"
}

test_acl_persisted_invalid_exact_ipv4_rejected() {
  local domain="acl-persist-invalid-ip.test"
  local rules_file output status

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  rules_file="${CONFIG_DIR}/security_ip_rules.csv"
  cat >"$rules_file" <<EOF_RULE
enabled,domain,scope,action,ip_value,status_code
1,${domain},l7,allow,999.999.999.999,
EOF_RULE

  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail on persisted invalid exact ipv4 acl" 0 "$status"
  assertStringContains "persisted invalid exact ip context" "Invalid persisted ACL rule at line 2 for domain '${domain}'" "$output"
  assertStringContains "persisted invalid exact ip reason" "Invalid IP/CIDR for ACL scope 'l7' action 'allow': 999.999.999.999" "$output"
}

test_acl_persisted_invalid_status_code_rejected() {
  local domain="acl-persist-invalid-code.test"
  local rules_file output status

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  rules_file="${CONFIG_DIR}/security_ip_rules.csv"
  cat >"$rules_file" <<EOF_RULE
enabled,domain,scope,action,ip_value,status_code
1,${domain},l7,deny,192.0.2.10,451; return 200;
EOF_RULE

  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail on persisted invalid acl status code" 0 "$status"
  assertStringContains "persisted invalid status context" "Invalid persisted ACL rule at line 2 for domain '${domain}'" "$output"
  assertStringContains "persisted invalid status reason" "Invalid status code for ACL scope 'l7' action 'deny': 451; return 200;" "$output"
}
