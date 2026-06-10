#!/usr/bin/env bash

test_add_port_https_http3_accepts_alt_svc_semicolon() {
  local domain="add-http3-alt-svc-semicolon.test"
  local listen_port="19445"
  local alt_svc_value="h3=:19445;ma=120"

  run_dockistrate add-backend "$domain" nginx:alpine 7007 http >/dev/null
  assertEquals "seed backend for add-port alt-svc semicolon" 0 $?

  local output status
  output="$(run_dockistrate add-port "$domain" "$listen_port" 7007 https none no --http3 on --alt-svc "$alt_svc_value")"
  status=$?
  assertEquals "add-port https --http3 on with semicolon alt-svc should succeed" 0 "$status"
  assertStringContains "add-port https --http3 output" "Added port mapping: domain=$domain => port $listen_port (proto=https)." "$output"

  local stored_http3 stored_alt_svc
  stored_http3="$(awk -F',' -v d="$domain" -v p="$listen_port" 'NR>1 && $1=="port" && $2==d && $7==p {print $14; exit}' "${CONFIG_DIR}/backend_ports.csv")"
  stored_alt_svc="$(awk -F',' -v d="$domain" -v p="$listen_port" 'NR>1 && $1=="port" && $2==d && $7==p {print $15; exit}' "${CONFIG_DIR}/backend_ports.csv")"
  assertEquals "stored http3 flag should be on for add-port semicolon alt-svc" "on" "$stored_http3"
  assertEquals "stored alt-svc should preserve semicolon params for add-port" "$alt_svc_value" "$stored_alt_svc"
}
