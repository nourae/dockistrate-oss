#!/usr/bin/env bash

test_update_port_only_updates_exact_domain_match() {
  run_dockistrate add-backend test-example.com nginx:alpine 9100 http >/dev/null
  assertEquals "seed hyphenated backend" 0 $?

  run_dockistrate add-port test-example.com 18180 9100 http none no >/dev/null
  assertEquals "seed hyphenated port" 0 $?

  run_dockistrate add-backend test.example.com nginx:alpine 9200 http >/dev/null
  assertEquals "seed dotted backend" 0 $?

  run_dockistrate add-port test.example.com 18180 9200 http none no >/dev/null
  assertEquals "seed dotted port" 0 $?

  local update_output
  update_output="$(run_dockistrate update-port test.example.com 18180 --container-port 9300)"
  assertEquals "update-port should succeed for dotted domain" 0 $?
  assertStringContains "update-port dotted output" "Updated port mapping for test.example.com on 18180." "$update_output"

  assertFileContains "port,test-example.com,,,,,18180,9100,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"
  assertFileContains "port,test.example.com,,,,,18180,9300,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"

  if grep -Fq "port,test.example.com,,,,,18180,9200,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"; then
    fail "Old port mapping for test.example.com should not remain after update"
  fi
}
