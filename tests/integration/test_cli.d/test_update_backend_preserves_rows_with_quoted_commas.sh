#!/usr/bin/env bash

test_update_backend_preserves_rows_with_quoted_commas() {
  local domain="quoted-update-backend.test"
  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend "$domain" nginx:alpine 7101 http >/dev/null
  assertEquals "seed backend for quoted update-backend test" 0 $?

  run_dockistrate add-port "$domain" 8443 7101 https none no >/dev/null
  assertEquals "seed https mapping for quoted update-backend test" 0 $?

  local quoted_rel="${domain}/selfsigned-8443"
  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  integration_seed_quoted_domain_fixture "$domain" 8443 || return

  local output
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$domain" --container-port 7201)"
  assertEquals "update-backend should succeed with quoted cert_ref rows" 0 $?
  assertStringContains "update-backend output" "Backend '${domain}' updated." "$output"

  assertFileContains "backend,${domain},172.30.0.2:7201,dockistrate-net,,,,,,,,," "$ports_file"
  assertFileContains "port,${domain},,,,,80,7201,http,none,no,off," "$ports_file"
  assertFileContains "port,${domain},,,,,8443,7201,https,${quoted_rel},no,off,,off,auto,,,,,," "$ports_file"
  integration_assert_quoted_domain_fixture "$domain"
}
