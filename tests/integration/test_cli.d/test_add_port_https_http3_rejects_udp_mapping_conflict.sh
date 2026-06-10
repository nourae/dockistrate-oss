#!/usr/bin/env bash

test_add_port_https_http3_rejects_udp_mapping_conflict() {
  run_dockistrate add-backend udp-owner-add-http3.test nginx:alpine 7000 udp --listen 8443 >/dev/null
  assertEquals "seed udp owner mapping on 8443" 0 $?

  run_dockistrate add-backend https-candidate-add-http3.test nginx:alpine 7001 http >/dev/null
  assertEquals "seed https candidate backend" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(run_dockistrate add-port https-candidate-add-http3.test 8443 7001 https none no --http3 on)"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "add-port https --http3 on should fail when udp mapping already owns the listen port" "[ $status -ne 0 ]"
  assertStringContains "add-port https --http3 on udp mapping conflict message" \
    "UDP port 8443 is already in use by another mapping." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed add-port https --http3 on" "$before" "$after"
}
