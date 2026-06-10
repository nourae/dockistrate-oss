#!/usr/bin/env bash

test_removing_one_of_multiple_https_backends_preserves_port_overrides() {
  run_dockistrate add-backend shared-a.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend shared-a" 0 $?

  run_dockistrate add-port shared-a.test 8443 9443 https none >/dev/null
  assertEquals "add-port shared-a" 0 $?

  run_dockistrate add-backend shared-b.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend shared-b" 0 $?

  run_dockistrate add-port shared-b.test 8443 9443 https none >/dev/null
  assertEquals "add-port shared-b" 0 $?

  run_dockistrate set-port-tls-protocols 8443 TLSv1.3 >/dev/null
  assertEquals "set-port-tls-protocols" 0 $?

  run_dockistrate set-port-tls-ciphers 8443 EECDH+AES256 >/dev/null
  assertEquals "set-port-tls-ciphers" 0 $?

  assertFileContains "8443,TLSv1.3" "${CONFIG_DIR}/port_tls_protocols.csv"
  assertFileContains "8443,EECDH+AES256" "${CONFIG_DIR}/port_tls_ciphers.csv"

  run_dockistrate remove-backend shared-a.test >/dev/null
  assertEquals "remove-backend shared-a" 0 $?

  assertFileContains "8443,TLSv1.3" "${CONFIG_DIR}/port_tls_protocols.csv"
  assertFileContains "8443,EECDH+AES256" "${CONFIG_DIR}/port_tls_ciphers.csv"
  assertFileContainsSubstring 'port,shared-b.test,,,,,8443,9443,https' "${CONFIG_DIR}/backend_ports.csv"
}
