#!/usr/bin/env bash

test_set_port_redirect_preserves_rows_with_quoted_commas() {
  local domain="quoted-redirect.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9100 http >/dev/null
  assertEquals "seed backend for quoted redirect test" 0 $?

  run_dockistrate add-port "$domain" 443 9100 https none no >/dev/null
  assertEquals "seed https mapping for quoted redirect test" 0 $?

  local quoted_rel="${domain}/selfsigned-443"
  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  integration_seed_quoted_domain_fixture "$domain" 443 || return

  local https_row_before
  https_row_before="$(grep -F "port,${domain},,,,,443,9100,https," "$ports_file")"

  local output
  output="$(run_dockistrate set-port-redirect "$domain" 80 on 301)"
  assertEquals "set-port-redirect should succeed with unrelated quoted cert_ref rows" 0 $?
  assertStringContains "set-port-redirect output" "Redirect on for ${domain} on port 80 (301)." "$output"

  assertFileContains "port,${domain},,,,,80,9100,http,none,no,on,301" "$ports_file"

  local https_row_after
  https_row_after="$(grep -F "port,${domain},,,,,443,9100,https," "$ports_file")"
  assertEquals "quoted https row should remain unchanged after redirect toggle on another row" "$https_row_before" "$https_row_after"
  integration_assert_quoted_domain_fixture "$domain"
}
