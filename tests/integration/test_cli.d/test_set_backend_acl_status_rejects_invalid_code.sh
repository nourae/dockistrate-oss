#!/usr/bin/env bash

test_set_backend_acl_status_rejects_invalid_code() {
  run_dockistrate add-backend acl-status-invalid.test nginx:alpine 7001 http >/dev/null
  assertEquals "seed backend for acl status" 0 $?

  local output status
  output="$(run_dockistrate set-backend-acl-status acl-status-invalid.test 42)"
  status=$?

  assertTrue "set-backend-acl-status with invalid code should fail" "[ $status -ne 0 ]"
  assertStringContains "invalid backend acl status error" "Invalid status code: 42" "$output"
  assertStringContains "invalid backend acl status guidance" "expected 100-599" "$output"
}
