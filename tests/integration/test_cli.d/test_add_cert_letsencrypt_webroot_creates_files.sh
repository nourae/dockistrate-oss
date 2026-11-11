#!/usr/bin/env bash

test_add_cert_letsencrypt_webroot_creates_files() {
  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend challenge.example nginx:alpine 8080 http >/dev/null
  assertEquals "seed HTTP listener for the webroot challenge" 0 $?
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for letsencrypt webroot" 0 $?

  local output status cert_dir
  output="$(DOCKER_MOCK_PORT_BINDINGS='80/tcp -> 0.0.0.0:80' run_dockistrate add-cert webroot.example 443 letsencrypt)"
  status=$?
  assertEquals "add-cert webroot letsencrypt should succeed" 0 $status
  assertStringContains "webroot mode indicator" "Using webroot mode" "$output"
  assertStringContains "letsencrypt placement message" "Let’s Encrypt cert placed" "$output"

  cert_dir="${STATE_DIR}/domains/webroot.example/certs/letsencrypt-443"
  assertTrue "webroot cert directory should exist" "[ -d '${cert_dir}' ]"
  assertTrue "webroot fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertTrue "webroot privkey should exist" "[ -f '${cert_dir}/privkey.pem' ]"
  assertFileContains "FAKE CERTIFICATE for webroot.example" "${cert_dir}/fullchain.pem"
  assertFileContains "FAKE PRIVATE KEY for webroot.example" "${cert_dir}/privkey.pem"
}
