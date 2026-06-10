#!/usr/bin/env bash

test_update_nginx_config_fails_on_tampered_backend_row() {
  run_dockistrate add-backend tampered-backend.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  local conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local before_conf
  before_conf="$(cat "$conf_file")"

  printf 'backend,tampered-backend.test,127.0.0.999:18180,dockistrate-net,,,,,,,,,,,,,,,,,\n' >>"${CONFIG_DIR}/backend_ports.csv"

  local output status
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail for tampered backend rows" 0 "$status"
  assertStringContains "failure should mention invalid backend upstream ip" "backend upstream IP '127.0.0.999' is invalid" "$output"

  local after_conf
  after_conf="$(cat "$conf_file")"
  assertEquals "backends.conf should be rolled back after backend row validation failure" "$before_conf" "$after_conf"
}
