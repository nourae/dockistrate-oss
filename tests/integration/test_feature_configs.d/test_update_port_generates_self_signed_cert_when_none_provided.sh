#!/usr/bin/env bash

test_update_port_generates_self_signed_cert_when_none_provided() {
  run_dockistrate add-backend update-https.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend update-https" 0 $?

  run_dockistrate add-port update-https.test 8443 18180 http none >/dev/null
  assertEquals "add-port update-https" 0 $?

  run_dockistrate remove-port update-https.test 80 >/dev/null
  assertEquals "remove-port default" 0 $?

  run_dockistrate update-port update-https.test --protocol https --cert none >/dev/null
  assertEquals "update-port update-https" 0 $?

  local expected_cert_dir="selfsigned/live/update-https.test_8443"
  assertTrue "self-signed cert directory should exist" "[ -d '${CERTS_DIR}/${expected_cert_dir}' ]"
  assertFileContainsSubstring "port,update-https.test,,,,,8443,18180,https,${expected_cert_dir}" "${CONFIG_DIR}/backend_ports.csv"
  assertFileContainsSubstring "${expected_cert_dir}/fullchain.pem" "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  assertFileContainsSubstring 'listen 8443 ssl;' "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
}
