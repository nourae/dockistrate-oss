#!/usr/bin/env bash

test_add_backend_rejects_busy_host_port_with_owner_and_suggestion() {
  local output status
  output="$(
    DOCKER_MOCK_PORT_BUSY_PORT=18180 \
      DOCKER_MOCK_PORT_BUSY_PID=4321 \
      DOCKER_MOCK_PORT_BUSY_PROC=BusyApp \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate add-backend busy-port.test nginx:alpine 18180 http --listen 18180
  )"
  status=$?

  assertTrue "add-backend should fail when requested listen port is busy" "[ $status -ne 0 ]"
  assertStringContains "busy-port error should include owner details" \
    "[Error] Host tcp port 18180 is already in use by PID 4321 (BusyApp)." "$output"
  assertStringContains "busy-port error should include dynamic suggestion" \
    "[Info] Suggested free port: 18181." "$output"

  output="$(
    DOCKER_MOCK_PORT_BUSY_PORT=18180 \
      DOCKER_MOCK_PORT_BUSY_PID=4321 \
      DOCKER_MOCK_PORT_BUSY_PROC=BusyApp \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate add-backend busy-port.test nginx:alpine 18180 http --listen 9090
  )"
  status=$?

  assertEquals "add-backend should succeed when using alternative port 9090" 0 "$status"
  assertFileContains "port,busy-port.test,,,,,9090,18180,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"
}
