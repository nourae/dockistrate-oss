#!/usr/bin/env bash

test_add_port_rejects_udp_conflict_with_http3() {
  run_dockistrate add-backend http3-owner.test nginx:alpine 9443 https --listen 8443 >/dev/null
  assertEquals "seed https owner backend" 0 $?

  run_dockistrate set-port-http3 8443 on >/dev/null
  assertEquals "enable http3 on 8443" 0 $?

  run_dockistrate add-backend udp-candidate.test nginx:alpine 7000 http >/dev/null
  assertEquals "seed udp candidate backend" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(run_dockistrate add-port udp-candidate.test 8443 7000 udp none no)"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "add-port udp should fail when https+http3 already occupies udp transport on same port" "[ $status -ne 0 ]"
  assertStringContains "add-port udp conflict message" \
    "UDP port 8443 is already in use by another mapping." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed udp add-port" "$before" "$after"
}
