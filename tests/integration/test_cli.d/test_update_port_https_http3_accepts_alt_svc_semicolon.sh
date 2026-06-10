#!/usr/bin/env bash

test_update_port_https_http3_accepts_alt_svc_semicolon() {
  local domain="update-http3-alt-svc-semicolon.test"
  local listen_port="19446"
  local alt_svc_value="h3=:19446;ma=180"

  run_dockistrate add-backend "$domain" nginx:alpine 7008 udp --listen "$listen_port" >/dev/null
  assertEquals "seed udp backend mapping for update-port semicolon alt-svc" 0 $?

  local output status
  output="$(run_dockistrate update-port "$domain" "$listen_port" --protocol https --cert none --http3 on --alt-svc "$alt_svc_value")"
  status=$?
  assertEquals "update-port udp->https --http3 on with semicolon alt-svc should succeed" 0 "$status"
  assertStringContains "update-port https --http3 output" "Updated port mapping for $domain on $listen_port." "$output"

  local stored_protocol stored_http3 stored_alt_svc
  stored_protocol="$(awk -F',' -v d="$domain" -v p="$listen_port" 'NR>1 && $1=="port" && $2==d && $7==p {print $9; exit}' "${CONFIG_DIR}/backend_ports.csv")"
  stored_http3="$(awk -F',' -v d="$domain" -v p="$listen_port" 'NR>1 && $1=="port" && $2==d && $7==p {print $14; exit}' "${CONFIG_DIR}/backend_ports.csv")"
  stored_alt_svc="$(awk -F',' -v d="$domain" -v p="$listen_port" 'NR>1 && $1=="port" && $2==d && $7==p {print $15; exit}' "${CONFIG_DIR}/backend_ports.csv")"
  assertEquals "stored protocol should be https after update-port semicolon alt-svc" "https" "$stored_protocol"
  assertEquals "stored http3 should be on after update-port semicolon alt-svc" "on" "$stored_http3"
  assertEquals "stored alt-svc should preserve semicolon params for update-port" "$alt_svc_value" "$stored_alt_svc"
}
