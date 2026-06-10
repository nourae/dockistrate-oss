#!/usr/bin/env bash

test_update_nginx_config_fails_on_tampered_path_row() {
  run_dockistrate add-backend tampered-path.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  local conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local before_conf
  before_conf="$(cat "$conf_file")"

  printf 'path,tampered-path.test,,,/api#oops,,80,,,,yes,off,,off,auto,prefix,100,,none,-,auto\n' >>"${CONFIG_DIR}/backend_ports.csv"

  local output status
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail for tampered path rows" 0 "$status"
  assertStringContains "failure should mention unsafe path prefix" "unsafe path prefix '/api#oops'" "$output"

  local after_conf
  after_conf="$(cat "$conf_file")"
  assertEquals "backends.conf should be rolled back after generation failure" "$before_conf" "$after_conf"
}
