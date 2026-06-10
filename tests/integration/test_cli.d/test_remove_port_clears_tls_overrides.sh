#!/usr/bin/env bash

test_remove_port_clears_tls_overrides() {
  run_dockistrate add-backend tls-clean.test nginx:alpine 9300 http >/dev/null
  assertEquals "seed backend for tls-clean" 0 $?

  run_dockistrate add-port tls-clean.test 4443 9300 https none no >/dev/null
  assertEquals "seed https port mapping" 0 $?

  run_dockistrate set-port-tls-protocols 4443 TLSv1.2 >/dev/null
  assertEquals "set-port-tls-protocols should succeed" 0 $?

  run_dockistrate set-port-tls-ciphers 4443 ECDHE-ECDSA-AES128-GCM-SHA256 >/dev/null
  assertEquals "set-port-tls-ciphers should succeed" 0 $?

  assertFileContains "4443,TLSv1.2" "${CONFIG_DIR}/port_tls_protocols.csv"
  assertFileContains "4443,ECDHE-ECDSA-AES128-GCM-SHA256" "${CONFIG_DIR}/port_tls_ciphers.csv"

  local remove_output
  remove_output="$(run_dockistrate remove-port tls-clean.test 4443)"
  assertEquals "remove-port should succeed" 0 $?
  assertStringContains "remove-port output mentions removal" "Removed port mapping" "$remove_output"

  if [ -f "${CONFIG_DIR}/port_tls_protocols.csv" ] &&
    grep -q '^4443,' "${CONFIG_DIR}/port_tls_protocols.csv"; then
    fail "Expected port_tls_protocols.csv to drop overrides for 4443"
  fi

  if [ -f "${CONFIG_DIR}/port_tls_ciphers.csv" ] &&
    grep -q '^4443,' "${CONFIG_DIR}/port_tls_ciphers.csv"; then
    fail "Expected port_tls_ciphers.csv to drop overrides for 4443"
  fi

  local status_output overrides_section
  status_output="$(run_dockistrate status)"
  assertEquals "status should succeed" 0 $?

  overrides_section="$(printf '%s\n' "$status_output" | awk 'BEGIN{flag=0} /^=== HTTPS Port TLS Overrides ===$/{flag=1;next} /^=== /{flag=0} flag')"
  if printf '%s\n' "$overrides_section" | grep -q '4443'; then
    fail "status reported stale TLS overrides for port 4443:\n${status_output}"
  fi
}
