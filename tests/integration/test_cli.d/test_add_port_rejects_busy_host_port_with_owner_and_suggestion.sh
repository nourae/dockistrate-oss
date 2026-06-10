#!/usr/bin/env bash

test_add_port_rejects_busy_host_port_with_owner_and_suggestion() {
  run_dockistrate add-backend add-port-busy.test nginx:alpine 7000 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(
    DOCKER_MOCK_PORT_BUSY_PORT=18180 \
      DOCKER_MOCK_PORT_BUSY_PID=2468 \
      DOCKER_MOCK_PORT_BUSY_PROC=AnotherApp \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate add-port add-port-busy.test 18180 7000 http none no
  )"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "add-port should fail when requested listen port is busy" "[ $status -ne 0 ]"
  assertStringContains "busy-port error should include owner details" \
    "[Error] Host tcp port 18180 is already in use by PID 2468 (AnotherApp)." "$output"
  assertStringContains "busy-port error should include dynamic suggestion" \
    "[Info] Suggested free port: 18181." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed add-port" "$before" "$after"
}
