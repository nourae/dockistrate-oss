#!/usr/bin/env bash

test_tls_configuration_generates_overrides() {
  run_dockistrate add-backend secure.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate add-port secure.test 8443 9443 https secure.test/selfsigned-443 no >/dev/null
  assertEquals "add-port should succeed" 0 $?

  run_dockistrate set-tls-protocols "TLSv1.2 TLSv1.3" >/dev/null
  assertEquals "set-tls-protocols quoted list" 0 $?

  run_dockistrate set-tls-ciphers EECDH+AESGCM >/dev/null
  assertEquals "set-tls-ciphers" 0 $?

  local global_settings_file="${CONFIG_DIR}/global_settings.csv"
  local failing_openssl_dir=""
  mkdir -p "$TMP_DIR"
  failing_openssl_dir="$(mktemp -d "${TMP_DIR}/failing-openssl.XXXXXX")" || {
    fail "Unable to create failing OpenSSL test directory"
    return 1
  }
  cat >"${failing_openssl_dir}/openssl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${failing_openssl_dir}/openssl"

  local invalid_syntax_global_output invalid_syntax_global_status
  invalid_syntax_global_output="$(
    PATH="${failing_openssl_dir}:$PATH" SKIP_DOCKER_CHECKS=true SKIP_UPDATE_NGINX_CONFIG=true \
      run_dockistrate set-tls-ciphers NOT_A_CIPHER
  )"
  invalid_syntax_global_status=$?
  assertTrue "set-tls-ciphers should fail closed when OpenSSL validation is unavailable" "[ ${invalid_syntax_global_status} -ne 0 ]"
  assertStringContains "global invalid cipher syntax error" "Invalid cipher string" "$invalid_syntax_global_output"
  assertEquals "Persisted global TLS cipher selection" "EECDH+AESGCM" "$(integration_global_csv_get "$global_settings_file" TLS_CIPHERS)"
  if grep -Fq 'NOT_A_CIPHER' "$global_settings_file"; then
    fail "Invalid global cipher syntax should not be persisted"
  fi

  local invalid_global_cipher_output invalid_global_cipher_status
  invalid_global_cipher_output="$(SKIP_UPDATE_NGINX_CONFIG=true run_dockistrate set-tls-ciphers 'HIGH;return 444')"
  invalid_global_cipher_status=$?
  assertTrue "set-tls-ciphers should reject Nginx directive-breaking cipher strings before state writes" "[ ${invalid_global_cipher_status} -ne 0 ]"
  assertStringContains "global directive-breaking cipher error" "unsafe Nginx directive characters" "$invalid_global_cipher_output"
  assertEquals "Persisted global TLS cipher selection" "EECDH+AESGCM" "$(integration_global_csv_get "$global_settings_file" TLS_CIPHERS)"

  local option_global_cipher_output option_global_cipher_status
  option_global_cipher_output="$(SKIP_UPDATE_NGINX_CONFIG=true run_dockistrate set-tls-ciphers -v)"
  option_global_cipher_status=$?
  assertTrue "set-tls-ciphers should reject option-shaped cipher strings before state writes" "[ ${option_global_cipher_status} -ne 0 ]"
  assertStringContains "global option-shaped cipher error" "cipher string is invalid" "$option_global_cipher_output"
  assertEquals "Persisted global TLS cipher selection" "EECDH+AESGCM" "$(integration_global_csv_get "$global_settings_file" TLS_CIPHERS)"
  if [ "$(integration_global_csv_get "$global_settings_file" TLS_CIPHERS)" = -v ]; then
    fail "Option-shaped global cipher syntax should not be persisted"
  fi

  integration_global_csv_set "$global_settings_file" TLS_CIPHERS "-v"
  local persisted_option_cipher_output persisted_option_cipher_status
  persisted_option_cipher_output="$(run_dockistrate update-nginx-config)"
  persisted_option_cipher_status=$?
  assertTrue "update-nginx-config should reject persisted option-shaped global cipher state" "[ ${persisted_option_cipher_status} -ne 0 ]"
  assertStringContains "persisted option-shaped cipher error" "cipher string is invalid" "$persisted_option_cipher_output"
  integration_global_csv_set "$global_settings_file" TLS_CIPHERS "EECDH+AESGCM"
  assertEquals "Persisted global TLS cipher selection" "EECDH+AESGCM" "$(integration_global_csv_get "$global_settings_file" TLS_CIPHERS)"

  run_dockistrate set-tls-ciphers '-AES:HIGH' >/dev/null
  assertEquals "set-tls-ciphers should preserve valid leading-minus cipher rules" 0 $?
  assertEquals "Persisted global TLS cipher selection" "-AES:HIGH" "$(integration_global_csv_get "$global_settings_file" TLS_CIPHERS)"
  run_dockistrate set-tls-ciphers 'EECDH+AESGCM' >/dev/null
  assertEquals "restore global TLS ciphers after leading-minus validation" 0 $?

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

  local invalid_syntax_port_output invalid_syntax_port_status
  invalid_syntax_port_output="$(
    PATH="${failing_openssl_dir}:$PATH" SKIP_DOCKER_CHECKS=true SKIP_UPDATE_NGINX_CONFIG=true \
      run_dockistrate set-port-tls-ciphers 8443 NOT_A_CIPHER
  )"
  invalid_syntax_port_status=$?
  assertTrue "set-port-tls-ciphers should fail closed when OpenSSL validation is unavailable" "[ ${invalid_syntax_port_status} -ne 0 ]"
  assertStringContains "port invalid cipher syntax error" "Invalid cipher string" "$invalid_syntax_port_output"
  assertFileContains "8443,EECDH+AES256" "${CONFIG_DIR}/port_tls_ciphers.csv"
  if grep -Fq 'NOT_A_CIPHER' "${CONFIG_DIR}/port_tls_ciphers.csv"; then
    fail "Invalid port cipher syntax should not be persisted"
  fi
  rm -rf "$failing_openssl_dir"

  local invalid_port_cipher_output invalid_port_cipher_status
  invalid_port_cipher_output="$(SKIP_UPDATE_NGINX_CONFIG=true run_dockistrate set-port-tls-ciphers 8443 'HIGH;return 444')"
  invalid_port_cipher_status=$?
  assertTrue "set-port-tls-ciphers should reject Nginx directive-breaking cipher strings before state writes" "[ ${invalid_port_cipher_status} -ne 0 ]"
  assertStringContains "port directive-breaking cipher error" "unsafe Nginx directive characters" "$invalid_port_cipher_output"
  assertFileContains "8443,EECDH+AES256" "${CONFIG_DIR}/port_tls_ciphers.csv"

  local option_port_cipher_output option_port_cipher_status
  option_port_cipher_output="$(SKIP_UPDATE_NGINX_CONFIG=true run_dockistrate set-port-tls-ciphers 8443 -v)"
  option_port_cipher_status=$?
  assertTrue "set-port-tls-ciphers should reject option-shaped cipher strings before state writes" "[ ${option_port_cipher_status} -ne 0 ]"
  assertStringContains "port option-shaped cipher error" "cipher string is invalid" "$option_port_cipher_output"
  assertFileContains "8443,EECDH+AES256" "${CONFIG_DIR}/port_tls_ciphers.csv"
  if grep -Fq '8443,-v' "${CONFIG_DIR}/port_tls_ciphers.csv"; then
    fail "Option-shaped port cipher syntax should not be persisted"
  fi

  run_dockistrate set-port-tls-ciphers 8443 '-AES:HIGH' >/dev/null
  assertEquals "set-port-tls-ciphers should preserve valid leading-minus cipher rules" 0 $?
  assertFileContains '8443,-AES:HIGH' "${CONFIG_DIR}/port_tls_ciphers.csv"
  run_dockistrate set-port-tls-ciphers 8443 'EECDH+AES256' >/dev/null
  assertEquals "restore port TLS ciphers after leading-minus validation" 0 $?

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
