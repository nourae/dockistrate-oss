#!/usr/bin/env bash

test_update_port_rejects_busy_host_port_with_owner_and_suggestion() {
  run_dockistrate add-backend update-port-busy.test nginx:alpine 7000 http --listen 9092 >/dev/null
  assertEquals "seed add-backend" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(
    DOCKER_MOCK_PORT_BUSY_PORT=18180 \
      DOCKER_MOCK_PORT_BUSY_PID=9876 \
      DOCKER_MOCK_PORT_BUSY_PROC=BindGuard \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-port update-port-busy.test 9092 --nginx-port 18180
  )"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "update-port should fail when requested listen port is busy" "[ $status -ne 0 ]"
  assertStringContains "busy-port error should include owner details" \
    "[Error] Host tcp port 18180 is already in use by PID 9876 (BindGuard)." "$output"
  assertStringContains "busy-port error should include dynamic suggestion" \
    "[Info] Suggested free port: 18181." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed update-port" "$before" "$after"
}
