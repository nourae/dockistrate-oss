#!/usr/bin/env bash

test_remove_backend_clears_tls_overrides() {
  run_dockistrate add-backend tls-prune.test nginx:alpine 9443 https --listen 4443 >/dev/null
  assertEquals "seed https backend" 0 $?

  run_dockistrate set-port-tls-protocols 4443 TLSv1.2 >/dev/null
  assertEquals "seed TLS protocols" 0 $?

  run_dockistrate set-port-tls-ciphers 4443 ECDHE-ECDSA-AES128-GCM-SHA256 >/dev/null
  assertEquals "seed TLS ciphers" 0 $?

  assertFileContains "4443,TLSv1.2" "${CONFIG_DIR}/port_tls_protocols.csv"
  assertFileContains "4443,ECDHE-ECDSA-AES128-GCM-SHA256" "${CONFIG_DIR}/port_tls_ciphers.csv"

  local remove_output
  remove_output="$(run_dockistrate remove-backend tls-prune.test)"
  assertEquals "remove-backend should succeed" 0 $?
  assertStringContains "remove-backend output" "Removed config entries" "$remove_output"

  if [ -f "${CONFIG_DIR}/port_tls_protocols.csv" ] &&
    grep -q '^4443,' "${CONFIG_DIR}/port_tls_protocols.csv"; then
    fail "Expected port_tls_protocols.csv to drop overrides for 4443"
  fi

  if [ -f "${CONFIG_DIR}/port_tls_ciphers.csv" ] &&
    grep -q '^4443,' "${CONFIG_DIR}/port_tls_ciphers.csv"; then
    fail "Expected port_tls_ciphers.csv to drop overrides for 4443"
  fi

  if [ -f "${CONFIG_DIR}/backend_ports.csv" ] &&
    grep -q '^port,tls-prune.test,,,,,4443,' "${CONFIG_DIR}/backend_ports.csv"; then
    fail "Expected backend_ports.csv to drop port mapping for tls-prune.test"
  fi

  local status_output overrides_section
  status_output="$(run_dockistrate status)"
  assertEquals "status should succeed" 0 $?

  overrides_section="$(printf '%s\n' "$status_output" | awk 'BEGIN{flag=0} /^=== HTTPS Port TLS Overrides ===$/{flag=1;next} /^=== /{flag=0} flag')"
  if printf '%s\n' "$overrides_section" | grep -q '4443'; then
    fail "status reported stale TLS overrides for port 4443:\n${status_output}"
  fi
}
