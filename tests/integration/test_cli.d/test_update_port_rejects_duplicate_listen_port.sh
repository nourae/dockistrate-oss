#!/usr/bin/env bash

test_update_port_rejects_duplicate_listen_port() {
  run_dockistrate add-backend duplicate.test nginx:alpine 7000 http >/dev/null
  assertEquals "seed duplicate backend" 0 $?

  run_dockistrate add-port duplicate.test 18180 7000 http none no >/dev/null
  assertEquals "seed first custom port" 0 $?

  run_dockistrate add-port duplicate.test 9090 7001 http none no >/dev/null
  assertEquals "seed second custom port" 0 $?

  local before
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  local output status
  output="$(run_dockistrate update-port duplicate.test 18180 --nginx-port 9090)"
  status=$?

  assertTrue "update-port should fail when port collides" "[ $status -ne 0 ]"
  assertStringContains "collision error message" "already exists" "$output"

  local after
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  assertEquals "backend_ports.csv should remain unchanged after failed update" "$before" "$after"
}
