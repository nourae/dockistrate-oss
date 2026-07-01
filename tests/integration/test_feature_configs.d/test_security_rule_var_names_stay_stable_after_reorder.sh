#!/usr/bin/env bash

extract_single_security_rule_var() {
  local needle="$1" file="$2"
  local line
  line="$(grep -F "$needle" "$file" | head -n 1)"
  printf '%s' "$line" | sed -n 's/.*set \$\([A-Za-z0-9_]*\)_p1 1; }.*/\1/p'
}

test_security_rule_var_names_stay_stable_after_reorder() {
  run_dockistrate add-backend stable-vars.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-security-rule stable-vars.test 1 header X-Base equals keep --code 451 >/dev/null
  assertEquals "seed base rule" 0 $?

  local rules_file="${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  local rules_db="${CONFIG_DIR}/security_rules.csv"
  local base_var_before
  base_var_before="$(extract_single_security_rule_var 'if ($http_x_base = "keep") { set $' "$rules_file")"
  if [ -z "$base_var_before" ]; then
    fail "base rule variable should be detected before reorder"
    return
  fi

  run_dockistrate add-security-rule stable-vars.test 1 header X-Other equals other --code 452 >/dev/null
  assertEquals "seed second rule" 0 $?

  local header row1 row2 tmp_file
  header="$(sed -n '1p' "$rules_db")"
  row1="$(sed -n '2p' "$rules_db")"
  row2="$(sed -n '3p' "$rules_db")"
  tmp_file="${rules_db}.tmp"
  {
    printf '%s\n' "$header"
    printf '%s\n' "$row2"
    printf '%s\n' "$row1"
  } >"$tmp_file"
  mv "$tmp_file" "$rules_db"

  local output
  output="$(run_dockistrate update-nginx-config 2>&1)"
  assertEquals "update-nginx-config after rule reorder" 0 $?

  local base_var_after
  base_var_after="$(extract_single_security_rule_var 'if ($http_x_base = "keep") { set $' "$rules_file")"
  if [ -z "$base_var_after" ]; then
    fail "base rule variable should be detected after reorder"
    return
  fi
  assertEquals "base rule variable should stay stable across reorder" "$base_var_before" "$base_var_after"
}
