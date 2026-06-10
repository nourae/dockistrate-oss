#!/usr/bin/env bash

test_update_nginx_config_fails_on_tampered_port_row() {
  run_dockistrate add-backend tampered-port.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  local conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local before_conf
  before_conf="$(cat "$conf_file")"

  printf 'port,tampered-port.test,,,,,8088,18180,http,none,no,on,999,off,auto,,,,,,\n' >>"${CONFIG_DIR}/backend_ports.csv"

  local output status
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail for tampered port rows" 0 "$status"
  assertStringContains "failure should mention invalid redirect code" "redirect code '999' is invalid" "$output"

  local after_conf
  after_conf="$(cat "$conf_file")"
  assertEquals "backends.conf should be rolled back after port row validation failure" "$before_conf" "$after_conf"
}
