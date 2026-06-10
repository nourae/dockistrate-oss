#!/usr/bin/env bash

test_add_port_treats_domain_dots_literally() {
  run_dockistrate add-backend test-example.com nginx:alpine 9100 http >/dev/null
  assertEquals "seed hyphenated backend" 0 $?

  run_dockistrate add-port test-example.com 18180 9100 http none no >/dev/null
  assertEquals "seed hyphenated port" 0 $?

  run_dockistrate add-backend test.example.com nginx:alpine 9200 http >/dev/null
  assertEquals "seed dotted backend" 0 $?

  local output
  output="$(run_dockistrate add-port test.example.com 18180 9200 http none no)"
  assertEquals "add-port should succeed for dotted domain" 0 $?
  assertStringContains "add-port dotted output" "Added port mapping" "$output"

  assertFileContains "port,test-example.com,,,,,18180,9100,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"
  assertFileContains "port,test.example.com,,,,,18180,9200,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"
}
