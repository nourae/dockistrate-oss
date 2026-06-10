#!/usr/bin/env bash

test_http_port_443_is_rejected() {
  local output status before after

  output="$(run_dockistrate add-backend reject-http-443.test nginx:alpine 18180 http --listen 443)"
  status=$?
  assertTrue "add-backend http --listen 443 should fail" "[ $status -ne 0 ]"
  assertStringContains "add-backend should explain 443 restriction" \
    "HTTP protocol is not allowed on port 443" "$output"

  run_dockistrate add-backend reject-http-port.test nginx:alpine 8081 http --no-expose >/dev/null
  assertEquals "seed backend without exposure" 0 $?

  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(run_dockistrate add-port reject-http-port.test 443 8081 http none no)"
  status=$?
  assertTrue "add-port http on 443 should fail" "[ $status -ne 0 ]"
  assertStringContains "add-port should explain 443 restriction" \
    "HTTP protocol is not allowed on port 443" "$output"
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  assertEquals "backend_ports.csv should remain unchanged after rejected add-port" "$before" "$after"

  run_dockistrate add-backend reject-http-update.test nginx:alpine 8082 http >/dev/null
  assertEquals "seed backend for update-port path" 0 $?

  before="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  output="$(run_dockistrate update-port reject-http-update.test 80 --nginx-port 443 --protocol http)"
  status=$?
  assertTrue "update-port to http on 443 should fail" "[ $status -ne 0 ]"
  assertStringContains "update-port should explain 443 restriction" \
    "HTTP protocol is not allowed on port 443" "$output"
  after="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  assertEquals "backend_ports.csv should remain unchanged after rejected update-port" "$before" "$after"
}
