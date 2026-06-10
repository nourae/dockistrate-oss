#!/usr/bin/env bash

test_header_overrides_generate_conf_includes() {
  local output
  output=$(run_dockistrate add-backend headers.test nginx:alpine 18180 http)
  assertEquals "add-backend" 0 $?

  output=$(run_dockistrate add-host-alias alias.headers.test headers.test)
  assertEquals "add-host-alias" 0 $?

  output=$(run_dockistrate add-backend other.test nginx:alpine 8081 http)
  assertEquals "add-backend other.test" 0 $?

  output=$(run_dockistrate add-header response X-Frame-Options DENY)
  assertEquals "add-header" 0 $?

  output=$(run_dockistrate add-backend-header headers.test request X-Trace Trace-Value)
  assertEquals "add-backend-header headers.test" 0 $?

  output=$(run_dockistrate add-backend-header alias.headers.test request X-Trace Alias-Trace-Value)
  assertEquals "add-backend-header alias.headers.test" 0 $?

  output=$(run_dockistrate add-backend-header other.test request X-Trace Other-Trace-Value)
  assertEquals "add-backend-header other.test" 0 $?

  assertFileContains "response,X-Frame-Options,DENY" "${CONFIG_DIR}/custom_headers.csv"
  assertFileContains "headers.test,request,X-Trace,Trace-Value" "${CONFIG_DIR}/backend_headers.csv"
  assertFileContains "alias.headers.test,request,X-Trace,Alias-Trace-Value" "${CONFIG_DIR}/backend_headers.csv"
  assertFileContains "other.test,request,X-Trace,Other-Trace-Value" "${CONFIG_DIR}/backend_headers.csv"
  assertFileContainsSubstring 'add_header X-Frame-Options "DENY" always;' "${CONFIG_DIR}/nginx_conf/conf.d/custom_headers.conf"
  assertFileContainsSubstring 'proxy_set_header X-Trace $backend_req_x_trace;' "${CONFIG_DIR}/nginx_conf/conf.d/backend_headers.conf"

  local maps_conf="${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
  assertFileContainsSubstring 'map $dockistrate_backend_header_key $backend_req_x_trace {' "$maps_conf"
  assertFileContainsSubstring 'headers.test "Trace-Value";' "$maps_conf"
  assertFileContainsSubstring 'alias.headers.test "Alias-Trace-Value";' "$maps_conf"
  assertFileContainsSubstring 'other.test "Other-Trace-Value";' "$maps_conf"

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local headers_block
  headers_block=$(awk '/server_name headers.test alias.headers.test;/,/^}/' "$backends_conf")

  assertStringContains "primary backend should default header identity to its primary domain" \
    'set $dockistrate_backend_header_key "headers.test";' "$headers_block"
  assertStringContains "alias match should override header identity inside the same server block" \
    'if ($host = alias.headers.test) { set $dockistrate_backend_header_key "alias.headers.test"; }' "$headers_block"
  assertFalse "primary backend block should not assign another backend identity" \
    "printf '%s\n' \"$headers_block\" | grep -Fq 'set \$dockistrate_backend_header_key \"other.test\";'"
}
