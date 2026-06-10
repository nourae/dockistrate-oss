#!/usr/bin/env bash

test_tls_configuration_generates_overrides() {
  run_dockistrate add-backend secure.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate add-port secure.test 8443 9443 https selfsigned/live/secure.test_443 no >/dev/null
  assertEquals "add-port should succeed" 0 $?

  run_dockistrate set-tls-protocols "TLSv1.2 TLSv1.3" >/dev/null
  assertEquals "set-tls-protocols quoted list" 0 $?

  run_dockistrate set-tls-ciphers EECDH+AESGCM >/dev/null
  assertEquals "set-tls-ciphers" 0 $?

  run_dockistrate set-port-tls-protocols 8443 "TLSv1.2 TLSv1.3" >/dev/null
  assertEquals "set-port-tls-protocols quoted list" 0 $?

  local glob_sentinel="${ROOT_DIR}/TLSv1.3" glob_sentinel_created="no"
  if [ ! -e "$glob_sentinel" ]; then
    touch "$glob_sentinel"
    glob_sentinel_created="yes"
  fi
  local invalid_protocols_output invalid_protocols_status
  invalid_protocols_output="$(run_dockistrate set-tls-protocols "TLSv1.*")"
  invalid_protocols_status=$?
  local invalid_port_protocols_output invalid_port_protocols_status
  invalid_port_protocols_output="$(run_dockistrate set-port-tls-protocols 8443 "TLSv1.*")"
  invalid_port_protocols_status=$?
  if [ "$glob_sentinel_created" = "yes" ]; then
    rm -f "$glob_sentinel"
  fi
  assertTrue "set-tls-protocols should reject glob-like protocol token" "[ ${invalid_protocols_status} -ne 0 ]"
  assertStringContains "global glob-like protocol error" "Invalid TLS protocol" "$invalid_protocols_output"
  assertTrue "set-port-tls-protocols should reject glob-like protocol token" "[ ${invalid_port_protocols_status} -ne 0 ]"
  assertStringContains "port glob-like protocol error" "Invalid TLS protocol" "$invalid_port_protocols_output"

  run_dockistrate set-port-tls-ciphers 8443 EECDH+AES256 >/dev/null
  assertEquals "set-port-tls-ciphers" 0 $?

  local missing_protocols_output missing_protocols_status
  missing_protocols_output="$(run_dockistrate set-port-tls-protocols)"
  missing_protocols_status=$?
  assertTrue "set-port-tls-protocols should fail without args" "[ ${missing_protocols_status} -ne 0 ]"
  assertStringContains "set-port-tls-protocols usage" \
    "[Usage] set-port-tls-protocols <port> <protocols...>" "$missing_protocols_output"

  local missing_ciphers_output missing_ciphers_status
  missing_ciphers_output="$(run_dockistrate set-port-tls-ciphers)"
  missing_ciphers_status=$?
  assertTrue "set-port-tls-ciphers should fail without args" "[ ${missing_ciphers_status} -ne 0 ]"
  assertStringContains "set-port-tls-ciphers usage" \
    "[Usage] set-port-tls-ciphers <port> <cipher string>" "$missing_ciphers_output"

  assertFileContains "8443,TLSv1.2 TLSv1.3" "${CONFIG_DIR}/port_tls_protocols.csv"
  assertFileContains "8443,EECDH+AES256" "${CONFIG_DIR}/port_tls_ciphers.csv"
  assertFileContainsSubstring 'ssl_protocols TLSv1.2 TLSv1.3;' "${CONFIG_DIR}/nginx_conf/conf.d/default.conf"
  assertFileContainsSubstring 'ssl_ciphers EECDH+AESGCM;' "${CONFIG_DIR}/nginx_conf/conf.d/default.conf"
  assertFileContainsSubstring 'ssl_protocols TLSv1.2 TLSv1.3;' "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  assertFileContainsSubstring 'ssl_ciphers   EECDH+AES256;' "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"

  run_dockistrate add-backend plain.test nginx:alpine 18180 http --listen 18180 >/dev/null
  assertEquals "add-backend http" 0 $?

  local fail_output fail_status
  fail_output="$(run_dockistrate set-port-tls-protocols 18180 TLSv1.2)"
  fail_status=$?
  assertTrue "set-port-tls-protocols should fail for HTTP port" "[ ${fail_status} -ne 0 ]"
  assertStringContains "http port protocol guard" "TLS overrides require HTTPS" "$fail_output"
  if [ -f "${CONFIG_DIR}/port_tls_protocols.csv" ] && grep -q '^18180,' "${CONFIG_DIR}/port_tls_protocols.csv"; then
    fail "HTTP port override should not be written to port_tls_protocols.csv"
  fi

  local cipher_fail_output cipher_fail_status
  cipher_fail_output="$(run_dockistrate set-port-tls-ciphers 18180 EECDH+AES128)"
  cipher_fail_status=$?
  assertTrue "set-port-tls-ciphers should fail for HTTP port" "[ ${cipher_fail_status} -ne 0 ]"
  assertStringContains "http port cipher guard" "TLS overrides require HTTPS" "$cipher_fail_output"
  if [ -f "${CONFIG_DIR}/port_tls_ciphers.csv" ] && grep -q '^18180,' "${CONFIG_DIR}/port_tls_ciphers.csv"; then
    fail "HTTP port override should not be written to port_tls_ciphers.csv"
  fi
}
