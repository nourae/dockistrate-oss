#!/usr/bin/env bash

test_manage_tcp_ports_with_port_commands() {
  run_dockistrate add-backend tcp.example.com nginx:alpine 6100 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  local output
  output="$(run_dockistrate add-port tcp.example.com 6200 6100 tcp none no)"
  assertEquals "add-port tcp should succeed" 0 $?
  assertStringContains "add-port tcp output" "proto=tcp" "$output"
  assertFileContains "port,tcp.example.com,,,,,6200,6100,tcp,,no,off," "${CONFIG_DIR}/backend_ports.csv"

  output="$(run_dockistrate update-port tcp.example.com 6200 --nginx-port 6300 --container-port 6101)"
  assertEquals "update-port tcp should succeed" 0 $?
  assertStringContains "update-port tcp output" "Updated port mapping for tcp.example.com on 6300" "$output"
  assertFileContains "port,tcp.example.com,,,,,6300,6101,tcp,,no,off," "${CONFIG_DIR}/backend_ports.csv"

  if grep -q '^port,tcp.example.com,,,,,6200,' "${CONFIG_DIR}/backend_ports.csv"; then
    fail "Old TCP port mapping for 6200 should have been replaced"
  fi
}
