#!/usr/bin/env bash

test_set_ws_flag_preserves_rows_with_quoted_commas() {
  local domain="quoted-ws-flag.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9300 http >/dev/null
  assertEquals "seed backend for quoted ws flag test" 0 $?

  run_dockistrate add-port "$domain" 443 9300 https none no >/dev/null
  assertEquals "seed https mapping for quoted ws flag test" 0 $?

  local quoted_rel="${domain}/selfsigned-443"
  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  integration_seed_quoted_domain_fixture "$domain" 443 || return

  local output
  output="$(run_dockistrate enable-ws "$domain" 443)"
  assertEquals "enable-ws should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "enable-ws output" "WebSocket enabled for ${domain} on port 443." "$output"
  assertFileContains "port,${domain},,,,,443,9300,https,${quoted_rel},yes,off,,off,auto,,,,,," "$ports_file"

  output="$(run_dockistrate disable-ws "$domain" 443)"
  assertEquals "disable-ws should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "disable-ws output" "WebSocket disabled for ${domain} on port 443." "$output"
  assertFileContains "port,${domain},,,,,443,9300,https,${quoted_rel},no,off,,off,auto,,,,,," "$ports_file"
  integration_assert_quoted_domain_fixture "$domain"
}
