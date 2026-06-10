#!/usr/bin/env bash

test_add_backend_creates_records_and_configs() {
  local output
  output="$(run_dockistrate add-backend example.com nginx:alpine 18180 http)"
  assertEquals "add-backend should exit successfully" 0 $?
  assertStringContains "logs add-backend output" "127.0.0.1:18180" "$output"

  assertFileContains "backend,example.com,127.0.0.1:18180,dockistrate-net,,,,,,,,," "${CONFIG_DIR}/backend_ports.csv"
  assertFileContains "port,example.com,,,,,80,18180,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"

  assertTrue "backends.conf should exist" "[ -f '${CONFIG_DIR}/nginx_conf/conf.d/backends.conf' ]"
  assertStringContains "backends.conf includes example.com" "server_name example.com;" "$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
}
