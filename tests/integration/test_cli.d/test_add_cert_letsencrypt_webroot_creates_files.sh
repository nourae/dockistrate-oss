#!/usr/bin/env bash

test_add_cert_letsencrypt_webroot_creates_files() {
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for letsencrypt webroot" 0 $?

  local output status cert_dir
  output="$(run_dockistrate add-cert webroot.example 443 letsencrypt)"
  status=$?
  assertEquals "add-cert webroot letsencrypt should succeed" 0 $status
  assertStringContains "webroot mode indicator" "Using webroot mode" "$output"
  assertStringContains "letsencrypt placement message" "Let’s Encrypt cert placed" "$output"

  cert_dir="${CERTS_DIR}/letsencrypt/live/webroot.example_443"
  if [ ! -d "$cert_dir" ]; then
    cert_dir="${CERTS_DIR}/letsencrypt/live/webroot.example"
  fi
  assertTrue "webroot cert directory should exist" "[ -d '${cert_dir}' ]"
  assertTrue "webroot fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertTrue "webroot privkey should exist" "[ -f '${cert_dir}/privkey.pem' ]"
  assertFileContains "FAKE CERTIFICATE for webroot.example" "${cert_dir}/fullchain.pem"
  assertFileContains "FAKE PRIVATE KEY for webroot.example" "${cert_dir}/privkey.pem"
}
