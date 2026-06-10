#!/usr/bin/env bash

test_set_port_http3_rejects_busy_udp_host_port() {
  run_dockistrate add-backend https-busy-set-http3.test nginx:alpine 9443 https --listen 8443 >/dev/null
  assertEquals "seed https mapping for set-port-http3 busy udp host check" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(
    DOCKER_MOCK_PORT_BUSY_PROTOCOL=udp \
      DOCKER_MOCK_PORT_BUSY_PORT=8443 \
      DOCKER_MOCK_PORT_BUSY_PID=9753 \
      DOCKER_MOCK_PORT_BUSY_PROC=UdpBusy \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate set-port-http3 8443 on
  )"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "set-port-http3 on should fail when host udp port is busy" "[ $status -ne 0 ]"
  assertStringContains "set-port-http3 on busy udp host message" \
    "[Error] Host udp port 8443 is already in use by PID 9753 (UdpBusy)." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed set-port-http3 on busy udp host port" "$before" "$after"
}
