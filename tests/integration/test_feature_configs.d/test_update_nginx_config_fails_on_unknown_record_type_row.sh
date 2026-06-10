#!/usr/bin/env bash

test_update_nginx_config_fails_on_unknown_record_type_row() {
  run_dockistrate add-backend tampered-unknown-type.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  local conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local before_conf
  before_conf="$(cat "$conf_file")"

  printf 'weird,tampered-unknown-type.test,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,\n' >>"${CONFIG_DIR}/backend_ports.csv"

  local output status
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail for unknown record types" 0 "$status"
  assertStringContains "failure should mention unknown row type" "unknown row type 'weird'" "$output"
  assertTrue "failure should remain controlled and not hit set -u unbound variable abort" "[[ \"$output\" != *\"unbound variable\"* ]]"

  local after_conf
  after_conf="$(cat "$conf_file")"
  assertEquals "backends.conf should be rolled back after unknown row-type validation failure" "$before_conf" "$after_conf"
}
