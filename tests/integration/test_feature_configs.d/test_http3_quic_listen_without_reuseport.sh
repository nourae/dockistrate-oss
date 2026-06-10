#!/usr/bin/env bash

test_http3_quic_listen_without_reuseport() {
  local domain="http3-no-reuseport.test"
  local listen_port="18443"

  run_dockistrate add-backend "$domain" nginx:alpine 9443 https --listen "$listen_port" >/dev/null
  assertEquals "seed https backend for quic listen rendering" 0 $?

  local output status
  output="$(run_dockistrate set-port-http3 "$listen_port" on)"
  status=$?
  assertEquals "set-port-http3 on should succeed for quic listen rendering" 0 "$status"
  assertStringContains "set-port-http3 output" \
    "Updated HTTP/3 for HTTPS port ${listen_port}: http3=on alt-svc=auto." "$output"

  output="$(run_dockistrate update-nginx-config)"
  status=$?
  assertEquals "update-nginx-config should succeed after enabling http3" 0 "$status"
  assertStringContains "update-nginx-config output" "Nginx configuration updated." "$output"

  assertTrue "rendered config should include quic listen directive" \
    "grep -R -Fq 'listen ${listen_port} quic;' '${CONFIG_DIR}/nginx_conf'"
  assertTrue "rendered config should not include quic reuseport directive" \
    "! grep -R -Fq 'listen ${listen_port} quic reuseport;' '${CONFIG_DIR}/nginx_conf'"
}
