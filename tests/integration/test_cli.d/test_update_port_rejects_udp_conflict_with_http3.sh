#!/usr/bin/env bash

test_update_port_rejects_udp_conflict_with_http3() {
  run_dockistrate add-backend http3-owner-update.test nginx:alpine 9443 https --listen 8443 >/dev/null
  assertEquals "seed https owner backend for update conflict" 0 $?

  run_dockistrate set-port-http3 8443 on >/dev/null
  assertEquals "enable http3 on 8443 for update conflict" 0 $?

  run_dockistrate add-backend udp-update-candidate.test nginx:alpine 7001 http --listen 8443 >/dev/null
  assertEquals "seed http mapping on shared 8443" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(run_dockistrate update-port udp-update-candidate.test 8443 --protocol udp)"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "update-port to udp should fail when https+http3 occupies udp transport on same port" "[ $status -ne 0 ]"
  assertStringContains "update-port udp conflict message" \
    "UDP port 8443 is already in use by another backend. Choose a different port." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed udp update-port" "$before" "$after"
}
