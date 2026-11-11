#!/usr/bin/env bash

test_remove_port_redirect_preserves_rows_with_quoted_commas() {
  local domain="quoted-remove-redirect.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9400 http >/dev/null
  assertEquals "seed backend for quoted remove redirect test" 0 $?

  run_dockistrate add-port "$domain" 443 9400 https none no >/dev/null
  assertEquals "seed https mapping for quoted remove redirect test" 0 $?

  run_dockistrate set-port-redirect "$domain" 80 on 301 >/dev/null
  assertEquals "enable redirect before remove test" 0 $?

  local quoted_rel="${domain}/selfsigned-443"
  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  integration_seed_quoted_domain_fixture "$domain" 443 || return

  local https_row_before
  https_row_before="$(grep -F "port,${domain},,,,,443,9400,https," "$ports_file")"

  local output
  output="$(run_dockistrate remove-port-redirect "$domain" 80)"
  assertEquals "remove-port-redirect should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "remove-port-redirect output" "Redirect disabled for ${domain} on port 80." "$output"

  assertFileContains "port,${domain},,,,,80,9400,http,none,no,off," "$ports_file"

  local https_row_after
  https_row_after="$(grep -F "port,${domain},,,,,443,9400,https," "$ports_file")"
  assertEquals "quoted https row should remain unchanged after redirect removal" "$https_row_before" "$https_row_after"
  integration_assert_quoted_domain_fixture "$domain"
}
