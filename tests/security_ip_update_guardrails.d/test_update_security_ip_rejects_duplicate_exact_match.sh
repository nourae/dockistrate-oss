#!/usr/bin/env bash

test_update_security_ip_rejects_duplicate_exact_match() {
  cat >"$SECURITY_IP_RULES_DB" <<'EOF_RULES'
enabled,domain,scope,action,ip_value,status_code
1,example.com,l7,allow,192.0.2.10,200
1,example.com,l7,allow,192.0.2.11,200
EOF_RULES

  local before output status
  before="$(read_rules_file)"
  output="$( (update_security_ip 2 --ip 192.0.2.10) 2>&1)"
  status=$?

  assertTrue "update-security-ip should reject duplicate exact rows" "[ $status -ne 0 ]"
  assertStringContains "duplicate acl error" "[Error] ACL rule already exists for example.com: scope=l7 action=allow ip=192.0.2.10 code=200" "$output"
  assertEquals "rule should remain unchanged" "$before" "$(read_rules_file)"
}
