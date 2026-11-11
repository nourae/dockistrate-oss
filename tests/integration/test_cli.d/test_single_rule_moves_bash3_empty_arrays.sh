#!/usr/bin/env bash

test_single_rule_moves_preserve_state_under_bash3() {
  local domain="single-rule-move.test"
  local acl_file="${CONFIG_DIR}/security_ip_rules.csv"
  local rules_file="${CONFIG_DIR}/security_rules.csv"
  local acl_before="${TMP_DIR}/single-acl-before.csv"
  local rules_before="${TMP_DIR}/single-rule-before.csv"
  local output status

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed single-rule backend" 0 $?

  run_dockistrate add-acl "$domain" l7 allow 192.0.2.10 >/dev/null
  assertEquals "seed single ACL rule" 0 $?
  cp "$acl_file" "$acl_before"
  output="$(run_dockistrate move-acl-rule 1 1 2>&1)"
  status=$?
  assertEquals "moving the sole ACL rule in place should succeed" 0 "$status"
  assertStringContains "single ACL move output" "Moved security IP rule 1 -> 1" "$output"
  assertTrue "single ACL move should preserve state byte-for-byte" "cmp -s '$acl_before' '$acl_file'"
  assertEquals "single ACL state should retain one row" "2" "$(awk 'END { print NR }' "$acl_file")"

  run_dockistrate add-security-rule "$domain" 1 header X-Single equals keep --code 451 >/dev/null
  assertEquals "seed single security rule" 0 $?
  cp "$rules_file" "$rules_before"
  output="$(run_dockistrate move-security-rule 1 1 2>&1)"
  status=$?
  assertEquals "moving the sole security rule in place should succeed" 0 "$status"
  assertStringContains "single security move output" "Moved rule 1 -> 1" "$output"
  assertTrue "single security move should preserve state byte-for-byte" "cmp -s '$rules_before' '$rules_file'"
  assertEquals "single security state should retain one row" "2" "$(awk 'END { print NR }' "$rules_file")"
  assertTrue "single ACL include should retain the rule" \
    "grep -Fq '192.0.2.10' '${CONFIG_DIR}/nginx_conf/conf.d/security_ip/${domain}.inc'"
  assertTrue "single security include should retain the rule" \
    "grep -Fq 'return 451;' '${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc'"
}
