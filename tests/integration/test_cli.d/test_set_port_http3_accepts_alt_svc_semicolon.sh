#!/usr/bin/env bash

test_set_port_http3_accepts_alt_svc_semicolon() {
  local domain="set-http3-alt-svc-semicolon.test"
  local listen_port="19447"
  local alt_svc_value="h3=:19447;ma=240"

  run_dockistrate add-backend "$domain" nginx:alpine 9443 https --listen "$listen_port" >/dev/null
  assertEquals "seed https backend mapping for set-port-http3 semicolon alt-svc" 0 $?

  local output status
  output="$(run_dockistrate set-port-http3 "$listen_port" on "$alt_svc_value")"
  status=$?
  assertEquals "set-port-http3 on with semicolon alt-svc should succeed" 0 "$status"
  assertStringContains "set-port-http3 output" \
    "Updated HTTP/3 for HTTPS port ${listen_port}: http3=on alt-svc=${alt_svc_value}." "$output"

  local stored_http3 stored_alt_svc
  stored_http3="$(awk -F',' -v d="$domain" -v p="$listen_port" 'NR>1 && $1=="port" && $2==d && $7==p {print $14; exit}' "${CONFIG_DIR}/backend_ports.csv")"
  stored_alt_svc="$(awk -F',' -v d="$domain" -v p="$listen_port" 'NR>1 && $1=="port" && $2==d && $7==p {print $15; exit}' "${CONFIG_DIR}/backend_ports.csv")"
  assertEquals "stored http3 should be on after set-port-http3 semicolon alt-svc" "on" "$stored_http3"
  assertEquals "stored alt-svc should preserve semicolon params for set-port-http3" "$alt_svc_value" "$stored_alt_svc"
}
