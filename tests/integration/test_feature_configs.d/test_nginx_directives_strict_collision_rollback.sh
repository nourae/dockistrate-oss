#!/usr/bin/env bash

test_nginx_directives_strict_collision_rollback() {
  local output

  output="$(run_dockistrate set-nginx-directive-strict off)"
  assertEquals "disable strict mode" 0 $?

  output="$(run_dockistrate set-nginx-directive-raw global server_tokens on)"
  assertEquals "seed unmanaged owned directive" 0 $?

  output="$(run_dockistrate set-nginx-directive-strict on 2>&1)"
  local status=$?
  assertNotEquals "strict mode enable should fail on unmanaged owned rows" 0 $status
  assertStringContains "strict collision message" "unmanaged state" "$output"

  output="$(run_dockistrate show-nginx-directive-strict)"
  assertEquals "strict mode should rollback to off after failed enable" "off" "$output"

  output="$(run_dockistrate remove-nginx-directive global server_tokens)"
  assertEquals "cleanup unmanaged owned row" 0 $?

  output="$(run_dockistrate set-nginx-directive-strict on)"
  assertEquals "strict mode enable after cleanup" 0 $?
}
