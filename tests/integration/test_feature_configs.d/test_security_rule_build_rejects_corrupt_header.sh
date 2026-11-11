#!/usr/bin/env bash

test_security_rule_build_rejects_corrupt_header() {
  local output status rules_file before_conf before_rules

  run_dockistrate add-backend sec-header-build.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?
  before_conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"

  rules_file="${STATE_DIR}/domains/sec-header-build.test/runtime/applied/security_rules.csv"
  cat >"$rules_file" <<'EOF_RULE'
wrong,header,for,security_rules
EOF_RULE
  before_rules="$(cat "$rules_file")"

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertNotEquals "update-nginx-config should fail on corrupted security rule header" 0 "$status"
  assertStringContains "invalid security rule header identifies the unknown column" "security_rules.csv: unknown field wrong" "$output"
  assertEquals "invalid header preserves the serving configuration" "$before_conf" "$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertEquals "invalid header rejection preserves the source for correction" "$before_rules" "$(cat "$rules_file")"
}
