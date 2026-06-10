#!/usr/bin/env bash

test_add_port_https_http3_rejects_busy_udp_host_port() {
  run_dockistrate add-backend udp-busy-add-http3.test nginx:alpine 7003 http >/dev/null
  assertEquals "seed backend for add-port https --http3 busy udp host check" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(
    DOCKER_MOCK_PORT_BUSY_PROTOCOL=udp \
      DOCKER_MOCK_PORT_BUSY_PORT=8443 \
      DOCKER_MOCK_PORT_BUSY_PID=2468 \
      DOCKER_MOCK_PORT_BUSY_PROC=UdpOwner \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate add-port udp-busy-add-http3.test 8443 7003 https none no --http3 on
  )"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "add-port https --http3 on should fail when host udp port is busy" "[ $status -ne 0 ]"
  assertStringContains "add-port https --http3 on busy udp host message" \
    "[Error] Host udp port 8443 is already in use by PID 2468 (UdpOwner)." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed add-port https --http3 on busy udp host port" "$before" "$after"
}
