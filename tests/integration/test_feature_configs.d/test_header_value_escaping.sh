#!/usr/bin/env bash

test_header_value_escaping() {
  run_dockistrate add-backend quote-header.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-header response X-Quoted 'foo "bar"' >/dev/null
  assertEquals "add-header" 0 $?
  run_dockistrate add-header response X-Echo -n >/dev/null
  assertEquals "add-header -n" 0 $?

  run_dockistrate add-backend-header quote-header.test response X-Quoted 'alpha "beta"' >/dev/null
  assertEquals "add-backend-header" 0 $?
  run_dockistrate add-backend-header quote-header.test response X-Echo -n >/dev/null
  assertEquals "add-backend-header -n" 0 $?

  assertFileContainsSubstring 'add_header X-Quoted "foo \"bar\"" always;' "${CONFIG_DIR}/nginx_conf/conf.d/custom_headers.conf"
  assertFileContainsSubstring 'add_header X-Echo "-n" always;' "${CONFIG_DIR}/nginx_conf/conf.d/custom_headers.conf"
  assertFileContainsSubstring 'quote-header.test "alpha \"beta\"";' "${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
  assertFileContainsSubstring 'quote-header.test "-n";' "${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
}
