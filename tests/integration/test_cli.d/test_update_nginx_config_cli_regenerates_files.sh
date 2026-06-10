#!/usr/bin/env bash

test_update_nginx_config_cli_regenerates_files() {
  run_dockistrate add-backend regen.test nginx:alpine 8123 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  local config_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  echo "# manual edit" >>"$config_file"

  local output
  output="$(run_dockistrate update-nginx-config)"
  assertEquals "update-nginx-config should succeed" 0 $?
  assertStringContains "update output" "Nginx configuration updated." "$output"

  local conf
  conf="$(cat "$config_file")"
  if grep -q "# manual edit" <<<"$conf"; then
    fail "update-nginx-config did not refresh backends.conf"
  fi
  assertStringContains "regenerated config includes domain" "regen.test" "$conf"
}
