#!/usr/bin/env bash

test_remove_cert_dependency_scan_handles_quoted_cert_ref() {
  local domain="guarded-quoted.test"
  run_dockistrate add-cert "$domain" 9443 selfsigned >/dev/null
  assertEquals "add-cert should succeed" 0 $?

  run_dockistrate add-backend "$domain" nginx:alpine 9501 http >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate add-cert "$domain" 9444 selfsigned >/dev/null
  assertEquals "seed a distinct owned certificate" 0 $?
  run_dockistrate add-port "$domain" 9443 9501 https "${domain}/selfsigned-9444" no >/dev/null
  assertEquals "add-port should succeed" 0 $?

  local src_dir="${STATE_DIR}/domains/${domain}/certs/selfsigned-9443"
  integration_seed_quoted_domain_fixture "$domain" 9443 selfsigned-9444 || return

  local remove_output remove_status
  remove_output="$(run_dockistrate remove-cert "$domain" 9443)"
  remove_status=$?

  assertEquals "remove-cert should succeed when quoted source references a different certificate" 0 "$remove_status"
  assertTrue "remove-cert output should not report dependency false-positive" "[[ \"$remove_output\" != *\"depend on it\"* ]]"
  integration_assert_quoted_domain_fixture "$domain"
  assertTrue "original certificate directory should be removed" "[ ! -d \"${src_dir}\" ]"
}
