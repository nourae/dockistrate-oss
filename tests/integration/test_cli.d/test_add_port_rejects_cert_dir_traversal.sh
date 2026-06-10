#!/usr/bin/env bash

test_add_port_rejects_cert_dir_traversal() {
  run_dockistrate add-backend https-traversal.test nginx:alpine 9103 http >/dev/null
  assertEquals "seed backend for traversal cert test" 0 $?

  local output status
  output="$(run_dockistrate add-port https-traversal.test 8666 9103 https certs/../../etc no)"
  status=$?

  assertTrue "add-port with path traversal should fail" "[ $status -ne 0 ]"
  assertStringContains "traversal error mentions rejection" \
    "Certificate directory 'certs/../../etc' must reside within" "$output"
}
