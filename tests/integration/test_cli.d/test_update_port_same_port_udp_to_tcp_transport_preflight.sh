#!/usr/bin/env bash

test_update_port_same_port_udp_to_tcp_transport_preflight() {
  local domain="same-port-udp-to-tcp-preflight.test"
  run_dockistrate add-backend "$domain" nginx:alpine 7011 http --listen 18182 >/dev/null
  assertEquals "seed backend for same-port udp->tcp transport preflight checks" 0 $?

  local output status before after
  output="$(run_dockistrate update-port "$domain" 18182 --protocol udp)"
  assertEquals "switch baseline mapping to udp on same listen port" 0 $?

  local target_protocol
  for target_protocol in http https tcp; do
    before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
    if [ "$target_protocol" = "https" ]; then
      output="$(
        DOCKER_MOCK_PORT_BUSY_PROTOCOL=tcp \
          DOCKER_MOCK_PORT_BUSY_PORT=18182 \
          DOCKER_MOCK_PORT_BUSY_PID=8899 \
          DOCKER_MOCK_PORT_BUSY_PROC=TcpBusyOwner \
          SKIP_DOCKER_CHECKS=false \
          run_dockistrate update-port "$domain" 18182 --protocol "$target_protocol" --cert none
      )"
    else
      output="$(
        DOCKER_MOCK_PORT_BUSY_PROTOCOL=tcp \
          DOCKER_MOCK_PORT_BUSY_PORT=18182 \
          DOCKER_MOCK_PORT_BUSY_PID=8899 \
          DOCKER_MOCK_PORT_BUSY_PROC=TcpBusyOwner \
          SKIP_DOCKER_CHECKS=false \
          run_dockistrate update-port "$domain" 18182 --protocol "$target_protocol"
      )"
    fi
    status=$?
    after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

    assertTrue "same-port udp->${target_protocol} should fail when host tcp port is busy" "[ $status -ne 0 ]"
    assertStringContains "same-port udp->${target_protocol} busy tcp host message" \
      "[Error] Host tcp port 18182 is already in use by PID 8899 (TcpBusyOwner)." "$output"
    assertEquals "backend_ports.csv should remain unchanged after failed same-port udp->${target_protocol} update-port" "$before" "$after"
  done
}
