#!/usr/bin/env bash

test_renew_certs_handles_quoted_cert_ref_paths() {
  local domain="quoted-renew-certs.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9500 http >/dev/null
  assertEquals "seed backend for renew-certs quoted path test" 0 $?

  run_dockistrate add-port "$domain" 9443 9500 https none no >/dev/null
  assertEquals "seed https mapping for renew-certs quoted path test" 0 $?

  local quoted_rel="${domain}/selfsigned-9443"
  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  integration_seed_quoted_domain_fixture "$domain" 9443 || return

  local output
  output="$(run_dockistrate renew-certs)"
  assertEquals "renew-certs should succeed with quoted cert_ref paths" 0 $?
  assertStringContains "renew-certs should report quoted cert path" "${quoted_rel} expires on" "$output"

  if printf '%s\n' "$output" | grep -Fq "Skipping invalid certificate path"; then
    fail "renew-certs should not report an invalid cert path for quoted source rows:\n${output}"
  fi
  integration_assert_quoted_domain_fixture "$domain"
}
