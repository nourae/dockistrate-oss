#!/usr/bin/env bash

test_add_port_rejects_external_cert_dir() {
  run_dockistrate add-backend https-external.test nginx:alpine 9102 http >/dev/null
  assertEquals "seed backend for external cert test" 0 $?

  local output status
  output="$(run_dockistrate add-port https-external.test 8555 9102 https /tmp/outside no)"
  status=$?

  assertTrue "add-port with external cert should fail" "[ $status -ne 0 ]"
  assertStringContains "error mentions external path rejection" \
    "must reside within" "$output"
}
