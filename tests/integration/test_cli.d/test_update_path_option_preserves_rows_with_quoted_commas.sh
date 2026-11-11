#!/usr/bin/env bash

test_update_path_option_preserves_rows_with_quoted_commas() {
  local domain="quoted-path-update.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9200 http >/dev/null
  assertEquals "seed backend for quoted path update test" 0 $?

  run_dockistrate add-path-option "$domain" 80 /api --ws yes --redirect off --headers none >/dev/null
  assertEquals "seed path override for quoted path update test" 0 $?

  run_dockistrate add-port "$domain" 443 9200 https none no >/dev/null
  assertEquals "seed https mapping for quoted path update test" 0 $?

  local quoted_rel="${domain}/selfsigned-443"
  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  integration_seed_quoted_domain_fixture "$domain" 443 || return

  local https_row_before
  https_row_before="$(grep -F "port,${domain},,,,,443,9200,https," "$ports_file")"

  local output
  output="$(run_dockistrate update-path-option "$domain" 80 /api --new-path /v2 --ws no --redirect 301 --headers none)"
  assertEquals "update-path-option should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "update-path-option output" "Updated path override ${domain}:80/v2." "$output"

  assertFileContains "path,${domain},,,/v2,,80,,,,no,on,301" "$ports_file"

  local https_row_after
  https_row_after="$(grep -F "port,${domain},,,,,443,9200,https," "$ports_file")"
  assertEquals "quoted https row should remain unchanged after path update" "$https_row_before" "$https_row_after"
  integration_assert_quoted_domain_fixture "$domain"
}
