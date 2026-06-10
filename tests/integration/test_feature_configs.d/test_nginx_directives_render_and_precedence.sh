#!/usr/bin/env bash

test_nginx_directives_render_and_precedence() {
  local output
  output="$(run_dockistrate add-backend precedence.test nginx:alpine 18180 http)"
  assertEquals "add-backend" 0 $?

  output="$(run_dockistrate set-nginx-directive global client_max_body_size 1m)"
  assertEquals "set global directive" 0 $?

  output="$(run_dockistrate set-nginx-directive backend precedence.test client_max_body_size 2m)"
  assertEquals "set backend directive" 0 $?

  output="$(run_dockistrate set-nginx-directive port precedence.test 80 client_max_body_size 3m)"
  assertEquals "set port directive" 0 $?

  local global_include="${CONFIG_DIR}/nginx_conf/conf.d/nginx_directives_global.inc"
  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"

  assertFileContainsSubstring 'client_max_body_size 1m;' "$global_include"
  assertFileContainsSubstring 'client_max_body_size 3m;' "$backends_conf"

  output="$(run_dockistrate remove-nginx-directive port precedence.test 80 client_max_body_size)"
  assertEquals "remove port directive" 0 $?

  assertFileContainsSubstring 'client_max_body_size 2m;' "$backends_conf"
  if grep -Fq 'client_max_body_size 3m;' "$backends_conf"; then
    fail "Expected port directive override (3m) to be removed from rendered server block"
  fi

  output="$(run_dockistrate remove-nginx-directive backend precedence.test client_max_body_size)"
  assertEquals "remove backend directive" 0 $?

  if grep -Fq 'client_max_body_size ' "$backends_conf"; then
    fail "Expected backend config to stop rendering client_max_body_size when only global value remains"
  fi
}
