#!/usr/bin/env bash

# Test dedicated host configuration
test_dedicated_host_generates_independent_server_block() {
  local output
  output=$(run_dockistrate add-backend dh.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.dh.test dh.test)
  assertEquals "add-dedicated-host" 0 $?

  # Verify dedicated host is listed
  output=$(run_dockistrate list-dedicated-hosts)
  assertStringContains "list output has admin.dh.test" "admin.dh.test" "$output"

  # Verify backends.conf has separate server blocks
  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  assertFileContainsSubstring 'server_name dh.test;' "$backends_conf"
  assertFileContainsSubstring 'server_name admin.dh.test;' "$backends_conf"
  assertFileContainsSubstring 'Dedicated host mapping for admin.dh.test' "$backends_conf"

  # Verify dedicated host has its own security_ip include
  local dh_security="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/admin.dh.test.inc"
  assertTrue "Dedicated host security_ip file exists" "[ -f '$dh_security' ]"
}

test_dedicated_host_with_independent_mtls() {
  local output
  output=$(run_dockistrate add-backend mtlsdh.test nginx:alpine 9443 https)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.mtlsdh.test mtlsdh.test)
  assertEquals "add-dedicated-host" 0 $?

  # Enable mTLS only on dedicated host
  output=$(run_dockistrate enable-backend-mtls admin.mtlsdh.test adminClient)
  assertEquals "enable-backend-mtls on dedicated host" 0 $?

  # Verify mTLS only applies to dedicated host
  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"

  # Get the section for admin.mtlsdh.test - should have ssl_verify_client
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.mtlsdh.test:443/,/^}/' "$backends_conf")

  # Dedicated host should have mTLS
  assertStringContains "mTLS ssl_verify_client" "ssl_verify_client" "$dh_block"
  assertStringContains "mTLS ssl_client_certificate" "ssl_client_certificate" "$dh_block"
}

test_dedicated_host_with_independent_acl() {
  local output
  output=$(run_dockistrate add-backend acldh.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.acldh.test acldh.test)
  assertEquals "add-dedicated-host" 0 $?

  # Add ACL allow rule only to dedicated host
  output=$(run_dockistrate add-acl admin.acldh.test l7 allow 10.0.0.0/8)
  assertEquals "add-acl to dedicated host" 0 $?

  # Verify ACL only applies to dedicated host
  local dh_acl="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/admin.acldh.test.inc"

  # Dedicated host should have allow rule
  assertFileContainsSubstring 'allow 10.0.0.0/8;' "$dh_acl"
}

test_remove_dedicated_host() {
  local output
  output=$(run_dockistrate add-backend rmdh.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.rmdh.test rmdh.test)
  assertEquals "add-dedicated-host" 0 $?

  # Verify it exists
  output=$(run_dockistrate list-dedicated-hosts)
  assertStringContains "list has admin.rmdh.test" "admin.rmdh.test" "$output"

  # Remove it
  output=$(run_dockistrate remove-dedicated-host admin.rmdh.test)
  assertEquals "remove-dedicated-host" 0 $?

  # Verify server block is removed from config
  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local conf_content
  conf_content=$(cat "$backends_conf")
  if [[ "$conf_content" == *"server_name admin.rmdh.test;"* ]]; then
    fail "Expected dedicated host server block to be removed"
  fi
}

test_remove_dedicated_host_colliding_with_backend_domain_removes_alias() {
  local output aliases_file http_file
  output=$(run_dockistrate add-backend collision-primary.test nginx:alpine 18180 http)
  assertEquals "add primary backend" 0 $?

  output=$(run_dockistrate set-backend-http-version collision-primary.test http1.1)
  assertEquals "set primary backend HTTP version" 0 $?

  output=$(run_dockistrate add-backend collision-owner.test nginx:alpine 18181 http)
  assertEquals "add owner backend" 0 $?

  aliases_file="${CONFIG_DIR}/backend_aliases.csv"
  printf '%s\n' 'dedicated,collision-primary.test,collision-owner.test' >>"$aliases_file"

  output=$(run_dockistrate remove-dedicated-host collision-primary.test)
  assertEquals "remove colliding dedicated host" 0 $?

  if grep -Fq 'dedicated,collision-primary.test,collision-owner.test' "$aliases_file"; then
    fail "Expected colliding dedicated host alias row to be removed"
  fi

  http_file="${CONFIG_DIR}/backend_http_versions.csv"
  assertFileContains "collision-primary.test,http1.1" "$http_file"
}

test_dedicated_host_rejects_existing_alias() {
  local output
  output=$(run_dockistrate add-backend aliasblock.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  # Add an alias first
  output=$(run_dockistrate add-host-alias existing.aliasblock.test aliasblock.test)
  assertEquals "add-host-alias" 0 $?

  # Try to add dedicated host with same hostname - should fail
  output=$(run_dockistrate add-dedicated-host existing.aliasblock.test aliasblock.test 2>&1)
  assertNotEquals "add-dedicated-host should reject existing alias" 0 $?
  assertStringContains "error mentions alias" "already exists as an alias" "$output"
}

test_dedicated_host_rejects_existing_backend() {
  local output
  output=$(run_dockistrate add-backend backendblock.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  # Try to add dedicated host with same hostname as backend - should fail
  output=$(run_dockistrate add-dedicated-host backendblock.test backendblock.test 2>&1)
  assertNotEquals "add-dedicated-host should reject existing backend" 0 $?
  assertStringContains "error mentions backend" "already a backend domain" "$output"
}

test_dedicated_host_inherits_mtls_from_target() {
  local output
  # Create backend with mTLS enabled
  output=$(run_dockistrate add-backend inheritdh.test nginx:alpine 9443 https)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate enable-backend-mtls inheritdh.test client1)
  assertEquals "enable-backend-mtls on target" 0 $?

  # Add dedicated host without explicit mTLS config
  output=$(run_dockistrate add-dedicated-host admin.inheritdh.test inheritdh.test)
  assertEquals "add-dedicated-host" 0 $?

  # Verify dedicated host inherits mTLS from target domain
  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.inheritdh.test:443/,/^}/' "$backends_conf")

  # Dedicated host should inherit mTLS from target
  assertStringContains "inherited mTLS ssl_verify_client" "ssl_verify_client" "$dh_block"
  assertStringContains "inherited mTLS ssl_client_certificate" "ssl_client_certificate" "$dh_block"
}

test_dedicated_host_inherits_acl_from_target() {
  local output
  # Create backend with ACL policy
  output=$(run_dockistrate add-backend inheritacl.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  # Set deny policy on target domain (default is deny, but explicit for clarity)
  output=$(run_dockistrate set-backend-acl-policy inheritacl.test deny)
  assertEquals "set-backend-acl-policy on target" 0 $?

  # Add ACL allow rule to target domain
  output=$(run_dockistrate add-acl inheritacl.test l7 allow 192.168.0.0/16)
  assertEquals "add-acl to target" 0 $?

  # Add dedicated host without explicit ACL config
  output=$(run_dockistrate add-dedicated-host admin.inheritacl.test inheritacl.test)
  assertEquals "add-dedicated-host" 0 $?

  # Verify dedicated host inherits ACL from target domain
  local dh_acl="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/admin.inheritacl.test.inc"
  local main_acl="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/inheritacl.test.inc"

  # Both should have allow rule (inherited)
  assertFileContainsSubstring 'allow 192.168.0.0/16;' "$dh_acl"
  assertFileContainsSubstring 'allow 192.168.0.0/16;' "$main_acl"
}

test_dedicated_host_explicit_default_acl_policy_overrides_inheritance() {
  local output
  output=$(run_dockistrate add-backend explicitacl.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate set-backend-acl-policy explicitacl.test allow)
  assertEquals "set-backend-acl-policy allow on target" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.explicitacl.test explicitacl.test)
  assertEquals "add-dedicated-host" 0 $?

  output=$(run_dockistrate set-backend-acl-policy admin.explicitacl.test deny)
  assertEquals "set-backend-acl-policy deny on dedicated host" 0 $?

  local dedicated_http_acl="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/admin.explicitacl.test.inc"
  local target_http_acl="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/explicitacl.test.inc"
  local dedicated_stream_acl="${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/admin.explicitacl.test.inc"
  local target_stream_acl="${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/explicitacl.test.inc"

  assertTrue "dedicated host HTTP ACL include exists" "[ -f \"$dedicated_http_acl\" ]"
  assertTrue "target HTTP ACL include exists" "[ -f \"$target_http_acl\" ]"
  assertTrue "dedicated host stream ACL include exists" "[ -f \"$dedicated_stream_acl\" ]"
  assertTrue "target stream ACL include exists" "[ -f \"$target_stream_acl\" ]"

  assertFileContainsSubstring 'deny all;' "$dedicated_http_acl"
  assertTrue "dedicated host HTTP ACL has L3 deny fallback variable" "grep -Eq '_l3_allow 0;' \"$dedicated_http_acl\""
  assertTrue "dedicated host HTTP ACL has L3 deny fallback return" "grep -Eq '_l3_allow = 0\\) \\{ return 403; \\}' \"$dedicated_http_acl\""
  assertFalse "target HTTP ACL should not contain deny all" "grep -Fq 'deny all;' \"$target_http_acl\""

  assertFileContainsSubstring 'deny all;' "$dedicated_stream_acl"
  assertFalse "target stream ACL should not contain deny all" "grep -Fq 'deny all;' \"$target_stream_acl\""
}

test_dedicated_host_explicit_default_acl_status_overrides_inheritance() {
  local output
  output=$(run_dockistrate add-backend explicitaclstatus.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate set-backend-acl-status explicitaclstatus.test 452)
  assertEquals "set-backend-acl-status on target" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.explicitaclstatus.test explicitaclstatus.test)
  assertEquals "add-dedicated-host" 0 $?

  output=$(run_dockistrate set-backend-acl-status admin.explicitaclstatus.test 403)
  assertEquals "set-backend-acl-status on dedicated host" 0 $?

  local dedicated_http_acl="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/admin.explicitaclstatus.test.inc"
  local target_http_acl="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/explicitaclstatus.test.inc"

  assertTrue "dedicated host HTTP ACL include exists" "[ -f \"$dedicated_http_acl\" ]"
  assertTrue "target HTTP ACL include exists" "[ -f \"$target_http_acl\" ]"
  assertFileContainsSubstring 'deny all;' "$dedicated_http_acl"
  assertFalse "dedicated host ACL should not inherit target 452 status" "grep -Fq 'return 452;' \"$dedicated_http_acl\""
  assertTrue "target ACL should keep explicit 452 status" "grep -Fq 'return 452;' \"$target_http_acl\""
}

test_dedicated_host_explicit_default_security_rule_status_overrides_inheritance() {
  local output
  output=$(run_dockistrate add-backend explicitsrstatus.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate set-backend-security-rule-status explicitsrstatus.test 452)
  assertEquals "set-backend-security-rule-status on target" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.explicitsrstatus.test explicitsrstatus.test)
  assertEquals "add-dedicated-host" 0 $?

  output=$(run_dockistrate set-backend-security-rule-status admin.explicitsrstatus.test 403)
  assertEquals "set-backend-security-rule-status on dedicated host" 0 $?

  output=$(run_dockistrate add-security-rule explicitsrstatus.test 1 header X-Block equals blocked)
  assertEquals "add-security-rule on target" 0 $?

  local rules_db="${CONFIG_DIR}/security_rules.csv"
  local rules_tmp="${rules_db}.tmp"
  awk -F, 'BEGIN { OFS="," } NR == 1 { print; next } { $2 = "admin.explicitsrstatus.test"; print }' "$rules_db" >"$rules_tmp"
  mv "$rules_tmp" "$rules_db"

  output=$(run_dockistrate set-backend-security-rule-status admin.explicitsrstatus.test 403)
  assertEquals "rebuild dedicated host security rule status" 0 $?

  local rules_file="${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  local dedicated_rule
  dedicated_rule=$(grep -F '$host = admin.explicitsrstatus.test' "$rules_file")

  assertStringContains "dedicated host security rule should use explicit 403" 'return 403;' "$dedicated_rule"
  assertFalse "dedicated host security rule should not inherit target 452 status" "printf '%s\n' \"$dedicated_rule\" | grep -Fq 'return 452;'"
}

test_dedicated_host_can_override_inherited_config() {
  local output
  # Create backend with mTLS enabled
  output=$(run_dockistrate add-backend overridedh.test nginx:alpine 9443 https)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate enable-backend-mtls overridedh.test client1)
  assertEquals "enable-backend-mtls on target" 0 $?

  # Add dedicated host
  output=$(run_dockistrate add-dedicated-host admin.overridedh.test overridedh.test)
  assertEquals "add-dedicated-host" 0 $?

  # Override with dedicated host's own mTLS
  output=$(run_dockistrate enable-backend-mtls admin.overridedh.test adminClient)
  assertEquals "enable-backend-mtls on dedicated host" 0 $?

  # Verify dedicated host uses its own mTLS config (admin.overridedh.test path)
  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.overridedh.test:443/,/^}/' "$backends_conf")

  # Dedicated host should have its own mTLS (pointing to admin.overridedh.test)
  assertStringContains "own mTLS ssl_verify_client" "ssl_verify_client" "$dh_block"
  assertStringContains "own mTLS path" "admin.overridedh.test" "$dh_block"
}

test_dedicated_host_inherits_headers_from_target() {
  local output
  output=$(run_dockistrate add-backend inherithdr.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-backend-header inherithdr.test request X-Trace Trace-Value)
  assertEquals "add-backend-header" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.inherithdr.test inherithdr.test)
  assertEquals "add-dedicated-host" 0 $?

  local maps_conf="${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
  assertFileContainsSubstring 'admin.inherithdr.test "Trace-Value";' "$maps_conf"

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.inherithdr.test:80/,/^}/' "$backends_conf")

  assertStringContains "dedicated host should set its own backend header identity" \
    'set $dockistrate_backend_header_key "admin.inherithdr.test";' "$dh_block"
}

test_dedicated_host_explicit_header_overrides_inherited_header() {
  local output
  output=$(run_dockistrate add-backend explicitdhhdr.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-backend-header explicitdhhdr.test request X-Trace Trace-Value)
  assertEquals "add-backend-header on target" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.explicitdhhdr.test explicitdhhdr.test)
  assertEquals "add-dedicated-host" 0 $?

  output=$(run_dockistrate add-backend-header admin.explicitdhhdr.test request X-Trace Dedicated-Trace-Value)
  assertEquals "add-backend-header on dedicated host" 0 $?

  local maps_conf="${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
  assertFileContainsSubstring 'explicitdhhdr.test "Trace-Value";' "$maps_conf"
  assertFileContainsSubstring 'admin.explicitdhhdr.test "Dedicated-Trace-Value";' "$maps_conf"

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.explicitdhhdr.test:80/,/^}/' "$backends_conf")

  assertStringContains "dedicated host explicit header should use dedicated host identity" \
    'set $dockistrate_backend_header_key "admin.explicitdhhdr.test";' "$dh_block"
}

test_dedicated_host_respects_inherit_headers_no() {
  local output
  output=$(run_dockistrate add-backend nohdr.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-backend-header nohdr.test request X-Trace Trace-Value)
  assertEquals "add-backend-header" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.nohdr.test nohdr.test yes yes yes no yes)
  assertEquals "add-dedicated-host" 0 $?

  local maps_conf="${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
  if grep -Fq 'admin.nohdr.test "Trace-Value";' "$maps_conf"; then
    fail "Expected dedicated host not to inherit headers when inherit_headers=no"
  fi
}

test_dedicated_host_inherits_client_and_proxy_ip_headers_from_target() {
  local output
  output=$(run_dockistrate set-client-ip-header off)
  assertEquals "set-client-ip-header off" 0 $?

  output=$(run_dockistrate set-proxy-ip-header off)
  assertEquals "set-proxy-ip-header off" 0 $?

  output=$(run_dockistrate add-backend inheritiphdr.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate set-backend-client-ip-header inheritiphdr.test X-Client-IP)
  assertEquals "set-backend-client-ip-header on target" 0 $?

  output=$(run_dockistrate set-backend-proxy-ip-header inheritiphdr.test X-Proxy-IP)
  assertEquals "set-backend-proxy-ip-header on target" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.inheritiphdr.test inheritiphdr.test)
  assertEquals "add-dedicated-host" 0 $?

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.inheritiphdr.test:80/,/^}/' "$backends_conf")

  assertStringContains "dedicated host should inherit real_ip_header" 'real_ip_header X-Client-IP;' "$dh_block"
  assertStringContains "dedicated host should inherit proxy IP header" 'proxy_set_header X-Proxy-IP $realip_remote_addr;' "$dh_block"
  assertStringContains "dedicated host should inherit client IP header" 'proxy_set_header X-Client-IP $remote_addr;' "$dh_block"
}

test_dedicated_host_client_and_proxy_ip_headers_respect_inherit_headers_no() {
  local output
  output=$(run_dockistrate set-client-ip-header off)
  assertEquals "set-client-ip-header off" 0 $?

  output=$(run_dockistrate set-proxy-ip-header off)
  assertEquals "set-proxy-ip-header off" 0 $?

  output=$(run_dockistrate add-backend noipinherit.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate set-backend-client-ip-header noipinherit.test X-Client-IP)
  assertEquals "set-backend-client-ip-header on target" 0 $?

  output=$(run_dockistrate set-backend-proxy-ip-header noipinherit.test X-Proxy-IP)
  assertEquals "set-backend-proxy-ip-header on target" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.noipinherit.test noipinherit.test yes yes yes no yes)
  assertEquals "add-dedicated-host" 0 $?

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.noipinherit.test:80/,/^}/' "$backends_conf")

  assertFalse "dedicated host should not inherit real_ip_header when inherit_headers=no" "printf '%s\n' \"$dh_block\" | grep -Fq 'real_ip_header X-Client-IP;'"
  assertFalse "dedicated host should not inherit proxy IP header when inherit_headers=no" "printf '%s\n' \"$dh_block\" | grep -Fq 'proxy_set_header X-Proxy-IP '"
  assertFalse "dedicated host should not inherit client IP header when inherit_headers=no" "printf '%s\n' \"$dh_block\" | grep -Fq 'proxy_set_header X-Client-IP '"
}

test_dedicated_host_can_explicitly_disable_inherited_client_and_proxy_ip_headers() {
  local output
  output=$(run_dockistrate set-client-ip-header off)
  assertEquals "set-client-ip-header off" 0 $?

  output=$(run_dockistrate set-proxy-ip-header off)
  assertEquals "set-proxy-ip-header off" 0 $?

  output=$(run_dockistrate add-backend offiphdr.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate set-backend-client-ip-header offiphdr.test X-Client-IP)
  assertEquals "set-backend-client-ip-header on target" 0 $?

  output=$(run_dockistrate set-backend-proxy-ip-header offiphdr.test X-Proxy-IP)
  assertEquals "set-backend-proxy-ip-header on target" 0 $?

  output=$(run_dockistrate add-dedicated-host admin.offiphdr.test offiphdr.test)
  assertEquals "add-dedicated-host" 0 $?

  output=$(run_dockistrate set-backend-client-ip-header admin.offiphdr.test off)
  assertEquals "set-backend-client-ip-header off on dedicated host" 0 $?

  output=$(run_dockistrate set-backend-proxy-ip-header admin.offiphdr.test off)
  assertEquals "set-backend-proxy-ip-header off on dedicated host" 0 $?

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local dh_block
  dh_block=$(awk '/Dedicated host mapping for admin.offiphdr.test:80/,/^}/' "$backends_conf")

  assertFalse "dedicated host explicit off should disable real_ip_header" "printf '%s\n' \"$dh_block\" | grep -Fq 'real_ip_header X-Client-IP;'"
  assertFalse "dedicated host explicit off should disable proxy IP header" "printf '%s\n' \"$dh_block\" | grep -Fq 'proxy_set_header X-Proxy-IP '"
  assertFalse "dedicated host explicit off should disable client IP header" "printf '%s\n' \"$dh_block\" | grep -Fq 'proxy_set_header X-Client-IP '"
  assertFileContains 'admin.offiphdr.test,off' "${CONFIG_DIR}/backend_client_ip_headers.csv"
  assertFileContains 'admin.offiphdr.test,off' "${CONFIG_DIR}/backend_proxy_ip_headers.csv"
}
