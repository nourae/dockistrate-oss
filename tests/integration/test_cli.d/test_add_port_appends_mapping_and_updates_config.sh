#!/usr/bin/env bash

test_add_port_appends_mapping_and_updates_config() {
  run_dockistrate add-backend example.org nginx:alpine 9000 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  local output
  output="$(run_dockistrate add-port example.org 8081 9000 http none no)"
  assertEquals "add-port should succeed" 0 $?
  assertStringContains "add-port output" "Added port mapping" "$output"

  assertFileContains "backend,example.org,127.0.0.1:9000,dockistrate-net,,,,,,,,," "${CONFIG_DIR}/backend_ports.csv"
  assertFileContains "port,example.org,,,,,8081,9000,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "new listener" "listen 8081;" "$conf"
  assertStringContains "proxy target" "proxy_pass http://127.0.0.1:9000;" "$conf"
}
