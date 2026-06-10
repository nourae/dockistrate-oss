#!/usr/bin/env bash

test_path_regex_strip_prefix_rewrite() {
  local domain="path-regex-strip-prefix.test"
  local regex_path='/rx[0-9]+/api'
  local prefix_path='/lit[0-9]+/api'
  local output

  output="$(run_dockistrate add-backend "$domain" nginx:alpine 18180 http)"
  assertEquals "add-backend path-regex-strip-prefix" 0 $?

  output="$(run_dockistrate add-path-option "$domain" 80 "$regex_path" --match regex --rewrite strip-prefix)"
  assertEquals "add regex path option with strip-prefix rewrite" 0 $?

  output="$(run_dockistrate add-path-option "$domain" 80 "$prefix_path" --match prefix --rewrite strip-prefix)"
  assertEquals "add prefix path option with strip-prefix rewrite" 0 $?

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local conf
  conf="$(cat "$backends_conf")"

  assertStringContains "regex location should render with regex matcher" "location ~* ${regex_path} {" "$conf"
  assertStringContains "regex strip-prefix rewrite should preserve regex semantics" \
    'rewrite ^/rx[0-9]+/api/?(.*)$ /$1 break;' "$conf"
  if printf '%s\n' "$conf" | grep -Fq 'rewrite ^/rx\[0-9\]\+/api/?(.*)$ /$1 break;'; then
    fail "Expected regex strip-prefix rewrite to remain unescaped when match=regex"
  fi

  assertStringContains "prefix location should render as plain prefix matcher" "location ${prefix_path} {" "$conf"
  assertStringContains "prefix strip-prefix rewrite should remain literal-escaped" \
    'rewrite ^/lit\[0-9\]\+/api/?(.*)$ /$1 break;' "$conf"
}
