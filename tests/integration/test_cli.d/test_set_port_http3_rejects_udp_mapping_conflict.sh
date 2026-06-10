#!/usr/bin/env bash

test_set_port_http3_rejects_udp_mapping_conflict() {
  run_dockistrate add-backend https-owner-set-http3.test nginx:alpine 9443 https --listen 8443 >/dev/null
  assertEquals "seed https mapping on 8443" 0 $?

  run_dockistrate add-backend udp-owner-set-http3.test nginx:alpine 7002 udp --listen 8443 >/dev/null
  assertEquals "seed udp mapping on 8443" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(run_dockistrate set-port-http3 8443 on)"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "set-port-http3 on should fail when udp mapping already owns the listen port" "[ $status -ne 0 ]"
  assertStringContains "set-port-http3 on udp mapping conflict message" \
    "UDP port 8443 is already in use by another mapping." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed set-port-http3 on" "$before" "$after"
}
