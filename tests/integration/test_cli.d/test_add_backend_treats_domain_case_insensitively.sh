#!/usr/bin/env bash

test_add_backend_treats_domain_case_insensitively() {
  run_dockistrate add-backend Example.com nginx:alpine 7100 http >/dev/null
  assertEquals "seed backend with mixed case" 0 $?

  local output status
  output="$(run_dockistrate add-backend example.com nginx:alpine 7100 http)"
  status=$?

  assertTrue "second add-backend with lower-case should fail" "[ $status -ne 0 ]"
  assertStringContains "case-insensitive duplicate error" "already exists" "$output"
  assertStringContains "case-insensitive duplicate guidance" "remove-backend example.com" "$output"
}
