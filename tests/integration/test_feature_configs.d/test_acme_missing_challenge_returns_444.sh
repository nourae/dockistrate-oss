#!/usr/bin/env bash

test_acme_missing_challenge_returns_444() {
  run_dockistrate add-backend acme.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate add-dedicated-host admin.acme.test acme.test >/dev/null
  assertEquals "add-dedicated-host should succeed" 0 $?

  local default_conf="${CONFIG_DIR}/nginx_conf/conf.d/default.conf"
  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local backend_block dedicated_block

  assertFileContainsSubstring 'location /.well-known/acme-challenge/ {' "$default_conf"
  assertFileContainsSubstring 'try_files $uri =444;' "$default_conf"

  backend_block="$(awk '/^[[:space:]]*server_name acme\.test;$/,/^}/' "$backends_conf")"
  assertStringContains "backend block should exist" 'server_name acme.test;' "$backend_block"
  assertStringContains "backend ACME location should be emitted" 'location /.well-known/acme-challenge/ {' "$backend_block"
  assertStringContains "backend ACME miss should return 444" 'try_files $uri =444;' "$backend_block"

  dedicated_block="$(awk '/^[[:space:]]*server_name admin\.acme\.test;$/,/^}/' "$backends_conf")"
  assertStringContains "dedicated-host block should exist" 'server_name admin.acme.test;' "$dedicated_block"
  assertStringContains "dedicated-host ACME location should be emitted" 'location /.well-known/acme-challenge/ {' "$dedicated_block"
  assertStringContains "dedicated-host ACME miss should return 444" 'try_files $uri =444;' "$dedicated_block"
}
