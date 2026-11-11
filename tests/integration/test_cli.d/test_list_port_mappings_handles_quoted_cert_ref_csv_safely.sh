#!/usr/bin/env bash

test_list_port_mappings_handles_quoted_cert_ref_csv_safely() {
  local domain="quoted-list-ports.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9301 http >/dev/null
  assertEquals "seed backend for list-port-mappings quoted test" 0 $?

  run_dockistrate add-port "$domain" 8443 9301 https none no >/dev/null
  assertEquals "seed https mapping for list-port-mappings quoted test" 0 $?

  local quoted_rel="${domain}/selfsigned-8443"
  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  integration_seed_quoted_domain_fixture "$domain" 8443 || return

  local output
  output="$(run_dockistrate list-port-mappings)"
  assertEquals "list-port-mappings should succeed with quoted cert_ref rows" 0 $?
  assertStringContains "list-port-mappings output should keep ws/redirect aligned" \
    "${domain} 8443 -> 9301 proto=https ws=no cert=${quoted_rel} redirect=off" "$output"
  integration_assert_quoted_domain_fixture "$domain"
}
