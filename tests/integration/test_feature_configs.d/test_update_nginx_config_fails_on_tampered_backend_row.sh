#!/usr/bin/env bash

test_update_nginx_config_repairs_tampered_backend_cache() {
  run_dockistrate add-backend tampered-backend.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  local conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local before_conf
  before_conf="$(cat "$conf_file")"

  printf 'backend,tampered-backend.test,127.0.0.999:18180,dockistrate-net,,,,,,,,,,,,,,,,,\n' >>"${CONFIG_DIR}/backend_ports.csv"

  local output status
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertEquals "update-nginx-config rebuilds derived backend rows from accepted source" 0 "$status"
  assertFalse "invalid cached upstream must be removed" "grep -Fq '127.0.0.999' '${CONFIG_DIR}/backend_ports.csv'"

  local after_conf
  after_conf="$(cat "$conf_file")"
  assertEquals "cache repair preserves the accepted serving configuration" "$before_conf" "$after_conf"
}
