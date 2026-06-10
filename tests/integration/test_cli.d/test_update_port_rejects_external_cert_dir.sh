#!/usr/bin/env bash

test_update_port_rejects_external_cert_dir() {
  local external_dir="${STATE_DIR}/external-certs/update-port-reject.test_8443"
  mkdir -p "$external_dir"
  printf 'CERT\n' >"${external_dir}/fullchain.pem"
  printf 'KEY\n' >"${external_dir}/privkey.pem"

  run_dockistrate add-backend update-port-reject.test nginx:alpine 9107 http >/dev/null
  assertEquals "seed backend for update-port rejection test" 0 $?

  local output status
  output="$(run_dockistrate update-port update-port-reject.test 80 --protocol https --cert "$external_dir" --ws no)"
  status=$?

  assertTrue "update-port with external cert should fail" "[ $status -ne 0 ]"
  assertStringContains "error mentions cert root containment" \
    "must reside within" "$output"
}
