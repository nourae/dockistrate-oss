#!/usr/bin/env bash

test_update_nginx_config_repairs_unknown_cached_record_type() {
  run_dockistrate add-backend tampered-unknown-type.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  local conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local before_conf
  before_conf="$(cat "$conf_file")"

  printf 'weird,tampered-unknown-type.test,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,\n' >>"${CONFIG_DIR}/backend_ports.csv"

  local output status
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertEquals "update-nginx-config rebuilds unknown derived rows from accepted source" 0 "$status"
  assertFalse "unknown cached row must be removed" "grep -q '^weird,' '${CONFIG_DIR}/backend_ports.csv'"
  assertTrue "cache repair must not hit set -u unbound variable abort" "[[ \"$output\" != *\"unbound variable\"* ]]"

  local after_conf
  after_conf="$(cat "$conf_file")"
  assertEquals "cache repair preserves the accepted serving configuration" "$before_conf" "$after_conf"
}
