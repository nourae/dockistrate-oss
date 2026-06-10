#!/usr/bin/env bash

test_update_port_https_http3_rejects_busy_udp_host_port() {
  run_dockistrate add-backend update-http3-busy-udp-candidate.test nginx:alpine 7006 http --listen 18081 >/dev/null
  assertEquals "seed candidate backend for update-port https http3 busy udp host check" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(
    DOCKER_MOCK_PORT_BUSY_PROTOCOL=udp \
      DOCKER_MOCK_PORT_BUSY_PORT=19444 \
      DOCKER_MOCK_PORT_BUSY_PID=6543 \
      DOCKER_MOCK_PORT_BUSY_PROC=UdpBindOwner \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-port update-http3-busy-udp-candidate.test 18081 --nginx-port 19444 --protocol https --cert none --http3 on --alt-svc auto
  )"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "update-port to https --http3 on should fail when host udp port is busy" "[ $status -ne 0 ]"
  assertStringContains "update-port https --http3 on busy udp host message" \
    "[Error] Host udp port 19444 is already in use by PID 6543 (UdpBindOwner)." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed update-port https --http3 on busy udp host port" "$before" "$after"
}
