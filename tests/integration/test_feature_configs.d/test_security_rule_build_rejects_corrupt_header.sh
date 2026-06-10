#!/usr/bin/env bash

test_security_rule_build_rejects_corrupt_header() {
  local output status rules_file

  run_dockistrate add-backend sec-header-build.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  rules_file="${CONFIG_DIR}/security_rules.csv"
  cat >"$rules_file" <<'EOF_RULE'
wrong,header,for,security_rules
EOF_RULE

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on corrupted security rule header" 0 "$status"
  assertStringContains "invalid security rule header context" "Invalid header in ${rules_file}" "$output"
}
