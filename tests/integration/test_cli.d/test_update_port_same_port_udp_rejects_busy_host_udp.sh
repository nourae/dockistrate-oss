#!/usr/bin/env bash

test_update_port_same_port_udp_rejects_busy_host_udp() {
  run_dockistrate add-backend update-same-port-udp-busy.test nginx:alpine 7010 http --listen 18181 >/dev/null
  assertEquals "seed backend for same-port update-port udp busy host check" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(
    DOCKER_MOCK_PORT_BUSY_PROTOCOL=udp \
      DOCKER_MOCK_PORT_BUSY_PORT=18181 \
      DOCKER_MOCK_PORT_BUSY_PID=7788 \
      DOCKER_MOCK_PORT_BUSY_PROC=UdpBusyOwner \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-port update-same-port-udp-busy.test 18181 --protocol udp
  )"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "update-port same-port to udp should fail when host udp port is busy" "[ $status -ne 0 ]"
  assertStringContains "update-port same-port udp busy host message" \
    "[Error] Host udp port 18181 is already in use by PID 7788 (UdpBusyOwner)." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed same-port udp update-port" "$before" "$after"
}
