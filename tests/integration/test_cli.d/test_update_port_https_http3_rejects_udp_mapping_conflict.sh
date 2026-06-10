#!/usr/bin/env bash

test_update_port_https_http3_rejects_udp_mapping_conflict() {
  run_dockistrate add-backend udp-owner-update-http3-conflict.test nginx:alpine 7004 udp --listen 19443 >/dev/null
  assertEquals "seed udp mapping owner for update-port https http3 conflict" 0 $?

  run_dockistrate add-backend update-http3-conflict-candidate.test nginx:alpine 7005 http --listen 18181 >/dev/null
  assertEquals "seed candidate backend for update-port https http3 conflict" 0 $?

  local before output status after
  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(run_dockistrate update-port update-http3-conflict-candidate.test 18181 --nginx-port 19443 --protocol https --cert none --http3 on --alt-svc auto)"
  status=$?
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"

  assertTrue "update-port to https --http3 on should fail when udp mapping already owns target listen port" "[ $status -ne 0 ]"
  assertStringContains "update-port https --http3 on udp mapping conflict message" \
    "UDP port 19443 is already in use by another backend. Choose a different port." "$output"
  assertEquals "backend_ports.csv should remain unchanged after failed update-port https --http3 on udp mapping conflict" "$before" "$after"
}
