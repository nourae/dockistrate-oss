#!/usr/bin/env bash

test_add_port_https_with_none_generates_self_signed_cert() {
  run_dockistrate add-backend https-none.test nginx:alpine 9101 http >/dev/null
  assertEquals "seed backend for https test" 0 $?

  local output
  output="$(run_dockistrate add-port https-none.test 8443 9101 https none no)"
  assertEquals "https add-port should succeed" 0 $?
  assertStringContains "https add-port output" "Added port mapping" "$output"

  local cert_dir="${CERTS_DIR}/selfsigned/live/https-none.test_8443"
  assertTrue "self-signed fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertTrue "self-signed privkey should exist" "[ -f '${cert_dir}/privkey.pem' ]"

  assertFileContains "port,https-none.test,,,,,8443,9101,https,selfsigned/live/https-none.test_8443,no,off," "${CONFIG_DIR}/backend_ports.csv"

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "https listener" "listen 8443 ssl;" "$conf"
  assertStringContains "cert path referenced" \
    "/etc/letsencrypt/selfsigned/live/https-none.test_8443" "$conf"
}
