#!/usr/bin/env bash

test_remove_cert_requires_detaching_https_ports() {
  run_dockistrate add-cert guarded.test 8443 selfsigned >/dev/null
  assertEquals "add-cert should succeed" 0 $?

  run_dockistrate add-backend guarded.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate add-port guarded.test 8443 9443 https selfsigned/live/guarded.test_8443 no >/dev/null
  assertEquals "add-port should succeed" 0 $?

  local remove_output remove_status cert_dir
  remove_output="$(run_dockistrate remove-cert guarded.test 8443)"
  remove_status=$?
  assertTrue "remove-cert should fail while port mappings depend on the cert" "[ ${remove_status} -ne 0 ]"
  assertStringContains "remove-cert failure message" "depend on it" "$remove_output"

  cert_dir="${CERTS_DIR}/selfsigned/live/guarded.test_8443"
  assertTrue "certificate directory should remain after failed removal" "[ -d '${cert_dir}' ]"
}
