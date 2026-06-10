#!/usr/bin/env bash

test_update_port_clears_cert_when_switching_to_http() {
  run_dockistrate add-backend http-switch.test nginx:alpine 7600 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  run_dockistrate add-cert http-switch.test 443 selfsigned >/dev/null
  assertEquals "seed certificate" 0 $?

  local update_output
  update_output="$(run_dockistrate update-port http-switch.test 80 --nginx-port 8443 --protocol https --cert certs/selfsigned/live/http-switch.test_443)"
  assertEquals "update-port https should succeed" 0 $?
  assertStringContains "https update output" "Updated port mapping" "$update_output"

  assertFileContains "port,http-switch.test,,,,,8443,7600,https,selfsigned/live/http-switch.test_443,no,off," "${CONFIG_DIR}/backend_ports.csv"

  local list_before
  list_before="$(run_dockistrate list-certs)"
  assertEquals "list-certs before http switch" 0 $?
  local before_line
  before_line="$(printf '%s\n' "$list_before" | grep -F 'http-switch.test_443' || true)"
  if [[ -z "$before_line" || "$before_line" != *"8443"* ]]; then
    fail "list-certs should report port 8443 before switching to HTTP:\n${list_before}"
  fi

  update_output="$(run_dockistrate update-port http-switch.test 8443 --nginx-port 18180 --protocol http)"
  assertEquals "update-port http should succeed" 0 $?
  assertStringContains "http update output" "Updated port mapping" "$update_output"

  assertFileContains "port,http-switch.test,,,,,18180,7600,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"
  if grep -q '^port,http-switch.test,,,,,8443,' "${CONFIG_DIR}/backend_ports.csv"; then
    fail "HTTPS port mapping should be removed after switching to HTTP"
  fi

  local list_after
  list_after="$(run_dockistrate list-certs)"
  assertEquals "list-certs after http switch" 0 $?
  local after_line
  after_line="$(printf '%s\n' "$list_after" | grep -F 'http-switch.test_443' || true)"
  if [ -z "$after_line" ]; then
    fail "list-certs output should include http-switch.test certificate after switching to HTTP:\n${list_after}"
  fi
  if [[ "$after_line" == *"8443"* ]]; then
    fail "list-certs should not list port 8443 after switching to HTTP:\n${list_after}"
  fi
}
