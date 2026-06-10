#!/usr/bin/env bash

test_update_security_ip_rejects_l7_deny_cidr_custom_status() {
  cat >"$SECURITY_IP_RULES_DB" <<'EOF_RULES'
enabled,domain,scope,action,ip_value,status_code
1,example.com,l7,deny,0.0.0.0/0,403
EOF_RULES

  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --code 418) 2>&1)"
  status=$?

  assertTrue "update-security-ip should reject l7 deny cidr custom status" "[ $status -ne 0 ]"
  assertStringContains "l7 cidr custom status error" "[Error] CIDR L7 deny rules always return 403; use status 403 or an exact IP for custom status: 0.0.0.0/0" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}

test_update_security_ip_rejects_exact_ip_custom_status_to_cidr() {
  cat >"$SECURITY_IP_RULES_DB" <<'EOF_RULES'
enabled,domain,scope,action,ip_value,status_code
1,example.com,l7,deny,192.0.2.10,418
EOF_RULES

  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 1 --ip 0.0.0.0/0) 2>&1)"
  status=$?

  assertTrue "update-security-ip should reject changing exact custom deny to cidr" "[ $status -ne 0 ]"
  assertStringContains "l7 cidr custom status error" "[Error] CIDR L7 deny rules always return 403; use status 403 or an exact IP for custom status: 0.0.0.0/0" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}

test_update_security_ip_allows_l7_deny_cidr_403() {
  cat >"$SECURITY_IP_RULES_DB" <<'EOF_RULES'
enabled,domain,scope,action,ip_value,status_code
1,example.com,l7,deny,0.0.0.0/0,
EOF_RULES

  local output status
  output="$(update_security_ip 1 --code 403 2>&1)"
  status=$?

  assertEquals "update-security-ip should allow l7 deny cidr with 403" 0 "$status"
  assertEquals "rule should contain cidr deny with 403" "example.com,l7,deny,0.0.0.0/0,403" "$(read_rules_file)"
}
