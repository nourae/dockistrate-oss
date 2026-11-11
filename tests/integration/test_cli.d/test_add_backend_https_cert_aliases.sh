#!/usr/bin/env bash

test_add_backend_https_selfsigned_cert_alias_creates_cert_ref() {
  local domain="backend-selfsigned-alias.test" output status cert_dir
  output="$(run_dockistrate add-backend "$domain" nginx:alpine 9443 https --listen 18443 --cert selfsigned)"
  status=$?
  assertEquals "add-backend https --cert selfsigned should succeed" 0 $status
  assertStringContains "add-backend selfsigned output" "Self-signed cert saved" "$output"

  cert_dir="${STATE_DIR}/domains/${domain}/certs/selfsigned-18443"
  assertTrue "selfsigned cert directory should exist" "[ -d '${cert_dir}' ]"
  assertTrue "selfsigned fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertFileContains "port,${domain},,,,,18443,9443,https,${domain}/selfsigned-18443,no,off," "${CONFIG_DIR}/backend_ports.csv"
}

test_add_backend_https_letsencrypt_cert_alias_creates_cert_ref() {
  local domain="backend-letsencrypt-alias.test" output status cert_dir
  output="$(run_dockistrate add-backend "$domain" nginx:alpine 9444 https --listen 18444 --cert letsencrypt)"
  status=$?
  assertEquals "add-backend https --cert letsencrypt should succeed" 0 $status
  assertStringContains "add-backend letsencrypt output" "Let's Encrypt" "$(printf '%s' "$output" | sed "s/Let’s/Let's/g")"
  assertStringContains "add-backend letsencrypt placement" "cert placed" "$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"

  cert_dir="${STATE_DIR}/domains/${domain}/certs/letsencrypt-18444"
  assertTrue "letsencrypt cert directory should exist" "[ -d '${cert_dir}' ]"
  assertTrue "letsencrypt fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertTrue "letsencrypt privkey should exist" "[ -f '${cert_dir}/privkey.pem' ]"
  assertFileContains "FAKE CERTIFICATE for ${domain}" "${cert_dir}/fullchain.pem"
  assertFileContains "port,${domain},,,,,18444,9444,https,${domain}/letsencrypt-18444,no,off," "${CONFIG_DIR}/backend_ports.csv"
}
