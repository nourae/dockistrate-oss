#!/usr/bin/env bash

test_remove_port_preserves_shared_tls_overrides() {
  run_dockistrate add-backend tls-shared-a.test nginx:alpine 9300 http >/dev/null
  assertEquals "seed backend tls-shared-a" 0 $?

  run_dockistrate add-backend tls-shared-b.test nginx:alpine 9301 http >/dev/null
  assertEquals "seed backend tls-shared-b" 0 $?

  run_dockistrate add-port tls-shared-a.test 4443 9300 https none no >/dev/null
  assertEquals "seed https port mapping for tls-shared-a" 0 $?

  run_dockistrate add-port tls-shared-b.test 4443 9301 https none no >/dev/null
  assertEquals "seed https port mapping for tls-shared-b" 0 $?

  run_dockistrate set-port-tls-protocols 4443 TLSv1.2 >/dev/null
  assertEquals "set-port-tls-protocols should succeed" 0 $?

  run_dockistrate set-port-tls-ciphers 4443 ECDHE-ECDSA-AES128-GCM-SHA256 >/dev/null
  assertEquals "set-port-tls-ciphers should succeed" 0 $?

  assertFileContains "4443,TLSv1.2" "${CONFIG_DIR}/port_tls_protocols.csv"
  assertFileContains "4443,ECDHE-ECDSA-AES128-GCM-SHA256" "${CONFIG_DIR}/port_tls_ciphers.csv"

  run_dockistrate remove-port tls-shared-a.test 4443 >/dev/null
  assertEquals "remove-port should succeed for first backend" 0 $?

  assertFileContains "4443,TLSv1.2" "${CONFIG_DIR}/port_tls_protocols.csv"
  assertFileContains "4443,ECDHE-ECDSA-AES128-GCM-SHA256" "${CONFIG_DIR}/port_tls_ciphers.csv"
  assertFileContains "port,tls-shared-b.test,,,,,4443,9301,https" "${CONFIG_DIR}/backend_ports.csv"
}
