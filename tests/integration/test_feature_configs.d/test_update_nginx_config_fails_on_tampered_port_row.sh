#!/usr/bin/env bash

test_update_nginx_config_fails_on_tampered_port_row() {
  run_dockistrate add-backend tampered-port.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  local conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local before_conf
  before_conf="$(cat "$conf_file")"

  if ! integration_domain_csv_set "${STATE_DIR}/domains/tampered-port.test/runtime/applied/ports.csv" 80 http redirect_code 999; then
    fail "Unable to seed invalid redirect code"
    return 1
  fi

  local output status
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail for tampered port rows" 0 "$status"
  assertStringContains "failure should identify the invalid accepted port settings" "ports.csv" "$output"

  local after_conf
  after_conf="$(cat "$conf_file")"
  assertEquals "backends.conf should be rolled back after port row validation failure" "$before_conf" "$after_conf"
}
