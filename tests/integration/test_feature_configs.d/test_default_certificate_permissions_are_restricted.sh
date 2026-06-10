#!/usr/bin/env bash

test_default_certificate_permissions_are_restricted() {
  DOCKER_MOCK_INSPECT_STATUS=running run_dockistrate start-nginx >/dev/null
  assertEquals "start-nginx should succeed" 0 $?

  local cert="${CONFIG_DIR}/nginx_conf/conf.d/default.crt"
  local key="${CONFIG_DIR}/nginx_conf/conf.d/default.key"
  local conf_dir="${CONFIG_DIR}/nginx_conf/conf.d"

  assertTrue "default certificate should exist" "[ -f '${cert}' ]"
  assertTrue "default key should exist" "[ -f '${key}' ]"

  local cert_mode key_mode dir_mode
  cert_mode="$(get_mode "$cert")"
  key_mode="$(get_mode "$key")"
  dir_mode="$(get_mode "$conf_dir")"

  assertEquals "default certificate should remain world-readable" "644" "$cert_mode"
  assertTrue "default key should not be more permissive than 0640" "[ ${key_mode} -le 640 ]"
  assertTrue "conf.d directory should not grant world permissions" "[ ${dir_mode: -1} = 0 ]"
}
