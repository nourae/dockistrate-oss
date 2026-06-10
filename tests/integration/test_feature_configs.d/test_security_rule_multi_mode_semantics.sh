#!/usr/bin/env bash

extract_security_rule_var() {
  local needle="$1" suffix="$2" file="$3"
  local line
  line="$(grep -F "$needle" "$file" | head -n 1)"
  printf '%s' "$line" | sed -n "s/.*set \\$\([A-Za-z0-9_]*\)${suffix}.*/\1/p"
}

test_security_rule_multi_mode_semantics() {
  run_dockistrate add-backend multi-mode.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-security-rule multi-mode.test 2 header X-A equals a header X-B not_equals b --mode and --code 451 >/dev/null
  assertEquals "add-security-rule and" 0 $?

  run_dockistrate add-security-rule multi-mode.test 2 header X-C equals c header X-D equals d --mode or --code 452 >/dev/null
  assertEquals "add-security-rule or" 0 $?

  local rules_file="${CONFIG_DIR}/nginx_conf/conf.d/security_rules.inc"
  local and_var or_var
  and_var="$(extract_security_rule_var 'if ($http_x_a = "a") { set $' '_p1 1; }' "$rules_file")"
  or_var="$(extract_security_rule_var 'if ($http_x_c = "c") { set $' '_pass 1; }' "$rules_file")"

  if [ -z "$and_var" ]; then
    fail "AND rule variable should be detected"
    return
  fi
  if [ -z "$or_var" ]; then
    fail "OR rule variable should be detected"
    return
  fi

  assertFileContainsSubstring "if (\$http_x_a = \"a\") { set \$${and_var}_p1 1; }" "$rules_file"
  assertFileContainsSubstring "if (\$http_x_b != \"b\") { set \$${and_var}_p2 1; }" "$rules_file"
  assertFileContainsSubstring "if (\$${and_var}_tmp = \"11\") { set \$${and_var}_fail 0; }" "$rules_file"
  assertFileContainsSubstring "if (\$${and_var}_fail = 1) { set \$dockistrate_rule_reason \"-\"; set \$dockistrate_rule_loc \"auto\"; return 451; }" "$rules_file"
  if grep -Fq "if (\$http_x_a != \"a\") { set \$${and_var}_p1 1; }" "$rules_file"; then
    fail "AND rule should not use inverted equals predicate"
    return
  fi
  if grep -Fq "if (\$http_x_b = \"b\") { set \$${and_var}_p2 1; }" "$rules_file"; then
    fail "AND rule should not use inverted not_equals predicate"
    return
  fi

  assertFileContainsSubstring "set \$${or_var}_pass 0;" "$rules_file"
  assertFileContainsSubstring "if (\$http_x_c = \"c\") { set \$${or_var}_pass 1; }" "$rules_file"
  assertFileContainsSubstring "if (\$http_x_d = \"d\") { set \$${or_var}_pass 1; }" "$rules_file"
  assertFileContainsSubstring "if (\$${or_var}_m = 1) { set \$${or_var}_fail 1; } if (\$${or_var}_pass = 1) { set \$${or_var}_fail 0; }" "$rules_file"
  assertFileContainsSubstring "if (\$${or_var}_fail = 1) { set \$dockistrate_rule_reason \"-\"; set \$dockistrate_rule_loc \"auto\"; return 452; }" "$rules_file"
  if grep -Fq "if (\$http_x_c != \"c\") { set \$${or_var}_pass 1; }" "$rules_file"; then
    fail "OR rule should not use inverted equals predicate"
    return
  fi
}
