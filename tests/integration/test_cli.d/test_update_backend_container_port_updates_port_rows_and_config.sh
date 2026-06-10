#!/usr/bin/env bash

test_update_backend_container_port_updates_port_rows_and_config() {
  run_dockistrate add-backend port-switch.test nginx:alpine 7100 http >/dev/null
  assertEquals "seed backend" 0 $?

  run_dockistrate add-port port-switch.test 18180 7100 http none no >/dev/null
  assertEquals "seed extra port" 0 $?

  run_dockistrate add-path-option port-switch.test 18180 /api --ws yes >/dev/null
  assertEquals "seed path override" 0 $?

  local output
  output="$(run_dockistrate update-backend port-switch.test --container-port 7200)"
  assertEquals "update-backend should succeed" 0 $?
  assertStringContains "update-backend output" "Backend 'port-switch.test' updated." "$output"

  assertFileContains "backend,port-switch.test,127.0.0.1:7200,dockistrate-net,,,,,,,,," "${CONFIG_DIR}/backend_ports.csv"
  assertFileContains "port,port-switch.test,,,,,80,7200,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"
  assertFileContains "port,port-switch.test,,,,,18180,7200,http,none,no,off," "${CONFIG_DIR}/backend_ports.csv"

  if grep -Fq ",port-switch.test,,,18180,7100," "${CONFIG_DIR}/backend_ports.csv"; then
    fail "Port mapping should not retain old upstream port after update"
  fi

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "backends.conf comment uses new upstream" \
    "# Additional mapping for port-switch.test:18180 => 127.0.0.1:7200" "$conf"
  assertStringContains "path override proxy_pass updated" "proxy_pass http://127.0.0.1:7200;" "$conf"

  if printf '%s\n' "$conf" | grep -Fq '127.0.0.1:7100'; then
    fail "backends.conf should not reference old upstream port"
  fi
}
