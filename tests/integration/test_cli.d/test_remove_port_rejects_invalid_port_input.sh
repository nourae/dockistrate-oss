#!/usr/bin/env bash

test_remove_port_rejects_invalid_port_input() {
  run_dockistrate add-backend remove-port-invalid.test nginx:alpine 9302 http >/dev/null
  assertEquals "seed backend for remove-port invalid input test" 0 $?

  run_dockistrate add-port remove-port-invalid.test 4443 9302 http none no >/dev/null
  assertEquals "seed port mapping for remove-port invalid input test" 0 $?

  local before_ports_checksum
  before_ports_checksum="$(cksum <"${CONFIG_DIR}/backend_ports.csv")"

  local output status
  output="$(run_dockistrate remove-port remove-port-invalid.test '44.*')"
  status=$?

  assertNotEquals "remove-port should fail for malformed port input" 0 "$status"
  assertStringContains "remove-port malformed port error" "Invalid port: 44.*" "$output"

  local after_ports_checksum
  after_ports_checksum="$(cksum <"${CONFIG_DIR}/backend_ports.csv")"
  assertEquals "backend_ports.csv should remain unchanged after invalid remove-port input" \
    "$before_ports_checksum" "$after_ports_checksum"
  assertFileContains "port,remove-port-invalid.test,,,,,4443,9302,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"
}
