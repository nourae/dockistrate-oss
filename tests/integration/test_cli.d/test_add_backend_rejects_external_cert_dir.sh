#!/usr/bin/env bash

test_add_backend_rejects_external_cert_dir() {
  local external_dir="${STATE_DIR}/external-certs/add-backend-reject.test_9443"
  mkdir -p "$external_dir"
  printf 'CERT\n' >"${external_dir}/fullchain.pem"
  printf 'KEY\n' >"${external_dir}/privkey.pem"

  local output status
  output="$(run_dockistrate add-backend add-backend-reject.test nginx:alpine 9443 https --listen 9443 --cert "$external_dir" --ws no)"
  status=$?

  assertTrue "add-backend with external cert should fail" "[ $status -ne 0 ]"
  assertStringContains "error mentions cert root containment" \
    "must reside within" "$output"
}
