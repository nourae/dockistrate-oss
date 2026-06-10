#!/usr/bin/env bash

test_backend_mtls_remove_after_revoke_is_idempotent() {
  run_dockistrate add-backend revoke-remove.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate enable-backend-mtls revoke-remove.test client1 >/dev/null
  assertEquals "enable-backend-mtls should succeed" 0 $?

  local mtls_dir
  mtls_dir="${CERTS_DIR}/mtls/revoke-remove.test"

  local serial_upper
  serial_upper="$(openssl x509 -in "${mtls_dir}/client1.crt" -serial -noout | cut -d= -f2 | tr '[:lower:]' '[:upper:]')"

  run_dockistrate revoke-backend-client-cert revoke-remove.test client1 >/dev/null
  assertEquals "revoke-backend-client-cert should succeed" 0 $?
  assertTrue "Client certificate should remain after revoke" "[ -f '${mtls_dir}/client1.crt' ]"
  assertTrue "Client key should remain after revoke" "[ -f '${mtls_dir}/client1.key' ]"

  run_dockistrate remove-backend-client-cert revoke-remove.test client1 >/dev/null
  assertEquals "remove-backend-client-cert should succeed after prior revoke" 0 $?
  assertTrue "Client certificate should be removed" "[ ! -e '${mtls_dir}/client1.crt' ]"
  assertTrue "Client key should be removed" "[ ! -e '${mtls_dir}/client1.key' ]"

  local crl_text
  crl_text="$(openssl crl -in "${mtls_dir}/ca.crl" -text -noout)"
  assertStringContains "CRL should retain the revoked certificate serial" "$serial_upper" "$crl_text"
}
