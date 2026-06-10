#!/usr/bin/env bash

test_add_backend_rejects_duplicate_domains() {
  run_dockistrate add-backend duplicate.test nginx:alpine 7000 http >/dev/null
  assertEquals "seed backend for duplicate" 0 $?

  local output status
  output="$(run_dockistrate add-backend duplicate.test nginx:alpine 7000 http)"
  status=$?

  assertTrue "second add-backend should fail" "[ $status -ne 0 ]"
  assertStringContains "duplicate backend error" "already exists" "$output"
  assertStringContains "duplicate backend hint" "remove-backend duplicate.test" "$output"
}
