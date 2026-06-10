#!/usr/bin/env bash

test_http3_udp_port_publish() {
  local domain="http3-udp.test"
  local docker_log_file="${STATE_DIR}/docker_http3_udp_publish.log"
  rm -f "$docker_log_file"

  run_dockistrate add-backend "$domain" nginx:alpine 9443 https --listen 8443 >/dev/null
  assertEquals "add-backend https 8443" 0 $?

  run_dockistrate set-port-http3 8443 on >/dev/null
  assertEquals "set-port-http3 on" 0 $?

  local output status
  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      DOCKER_MOCK_INSPECT_STATUS=running \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-nginx-config
  )"
  status=$?
  assertEquals "update-nginx-config with http3 enabled" 0 "$status"
  assertStringContains "config regeneration output (http3 on)" "Nginx configuration updated." "$output"
  assertTrue "nginx run should publish tcp binding for 8443" \
    "grep -Fq ' -p 8443:8443/tcp ' '${docker_log_file}'"
  assertTrue "nginx run should publish udp binding for 8443 when http3 is enabled" \
    "grep -Fq ' -p 8443:8443/udp ' '${docker_log_file}'"

  : >"$docker_log_file"
  run_dockistrate set-port-http3 8443 off >/dev/null
  assertEquals "set-port-http3 off" 0 $?

  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      DOCKER_MOCK_INSPECT_STATUS=running \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-nginx-config
  )"
  status=$?
  assertEquals "update-nginx-config with http3 disabled" 0 "$status"
  assertStringContains "config regeneration output (http3 off)" "Nginx configuration updated." "$output"
  assertTrue "nginx run should still publish tcp binding when http3 is disabled" \
    "grep -Fq ' -p 8443:8443/tcp ' '${docker_log_file}'"
  assertTrue "nginx run should not publish udp binding when http3 is disabled" \
    "! grep -Fq ' -p 8443:8443/udp ' '${docker_log_file}'"
}
