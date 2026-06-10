#!/usr/bin/env bash

test_mtls_private_keys_are_permission_restricted() {
  run_dockistrate add-backend mtls-perm.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate enable-backend-mtls mtls-perm.test >/dev/null
  assertEquals "enable-backend-mtls should succeed" 0 $?

  local mtls_dir ca_key ca_mode
  mtls_dir="${CERTS_DIR}/mtls/mtls-perm.test"
  ca_key="${mtls_dir}/ca.key"
  assertTrue "CA key should exist after enabling mTLS" "[ -f '${ca_key}' ]"

  ca_mode="$(get_mode "$ca_key")"
  assertEquals "CA key should be owner-only" "600" "$ca_mode"

  run_dockistrate add-backend-client-cert mtls-perm.test client1 >/dev/null
  assertEquals "add-backend-client-cert should succeed" 0 $?

  local client_key client_mode
  client_key="${mtls_dir}/client1.key"
  assertTrue "Client key should exist after add-backend-client-cert" "[ -f '${client_key}' ]"

  client_mode="$(get_mode "$client_key")"
  assertEquals "Client key should be owner-only" "600" "$client_mode"

  run_dockistrate replace-backend-ca mtls-perm.test >/dev/null
  assertEquals "replace-backend-ca should succeed" 0 $?
  assertTrue "CA key should exist after replacement" "[ -f '${ca_key}' ]"

  ca_mode="$(get_mode "$ca_key")"
  assertEquals "Replaced CA key should be owner-only" "600" "$ca_mode"
}

test_exported_pkcs12_is_permission_restricted() {
  run_dockistrate add-backend mtls-p12.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate enable-backend-mtls mtls-p12.test client1 >/dev/null
  assertEquals "enable-backend-mtls should succeed" 0 $?

  P12_EXPORT_PASSWORD="p12-password" run_dockistrate export-backend-client-p12 mtls-p12.test client1 --password-env P12_EXPORT_PASSWORD >/dev/null
  assertEquals "export-backend-client-p12 should succeed" 0 $?

  local p12_file p12_mode
  p12_file="${CERTS_DIR}/mtls/mtls-p12.test/client1.p12"
  assertTrue "PKCS#12 file should exist after export" "[ -f '${p12_file}' ]"

  p12_mode="$(get_mode "$p12_file")"
  assertEquals "PKCS#12 file should be owner-only" "600" "$p12_mode"
}
