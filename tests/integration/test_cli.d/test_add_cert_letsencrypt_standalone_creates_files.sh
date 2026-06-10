#!/usr/bin/env bash

test_add_cert_letsencrypt_standalone_creates_files() {
  local output status cert_dir
  output="$(run_dockistrate add-cert standalone.example 443 letsencrypt)"
  status=$?
  assertEquals "add-cert standalone letsencrypt should succeed" 0 $status
  assertStringContains "standalone mode indicator" "using standalone mode" "$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  assertStringContains "letsencrypt placement message" "Let’s Encrypt cert placed" "$output"

  cert_dir="${CERTS_DIR}/letsencrypt/live/standalone.example_443"
  if [ ! -d "$cert_dir" ]; then
    cert_dir="${CERTS_DIR}/letsencrypt/live/standalone.example"
  fi
  assertTrue "standalone cert directory should exist" "[ -d '${cert_dir}' ]"
  assertTrue "standalone fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertTrue "standalone privkey should exist" "[ -f '${cert_dir}/privkey.pem' ]"
  assertFileContains "FAKE CERTIFICATE for standalone.example" "${cert_dir}/fullchain.pem"
  assertFileContains "FAKE PRIVATE KEY for standalone.example" "${cert_dir}/privkey.pem"
}
