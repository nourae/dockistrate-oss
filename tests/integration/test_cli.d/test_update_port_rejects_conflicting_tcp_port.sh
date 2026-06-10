#!/usr/bin/env bash

test_update_port_rejects_conflicting_tcp_port() {
  run_dockistrate add-backend tcp-first.test nginx:alpine 9201 http >/dev/null
  assertEquals "seed first backend" 0 $?

  run_dockistrate add-port tcp-first.test 9020 9201 tcp none no >/dev/null
  assertEquals "seed tcp mapping" 0 $?

  run_dockistrate add-backend tcp-second.test nginx:alpine 9202 http >/dev/null
  assertEquals "seed second backend" 0 $?

  run_dockistrate add-port tcp-second.test 9020 9202 http none no >/dev/null
  assertEquals "seed http mapping on shared port" 0 $?

  local output status
  output="$(run_dockistrate update-port tcp-second.test 9020 --protocol tcp)"
  status=$?

  assertTrue "update-port should fail when TCP port already claimed" "[ $status -ne 0 ]"
  assertStringContains "conflicting TCP port error" \
    "TCP port 9020 is already in use by another backend. Choose a different port." "$output"
}
