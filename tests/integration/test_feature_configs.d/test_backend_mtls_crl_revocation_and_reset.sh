#!/usr/bin/env bash

test_backend_mtls_crl_revocation_and_reset() {
  run_dockistrate add-backend crl.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate enable-backend-mtls crl.test client1 >/dev/null
  assertEquals "enable-backend-mtls should succeed" 0 $?

  local mtls_dir
  mtls_dir="${CERTS_DIR}/mtls/crl.test"
  assertTrue "CA directory should exist" "[ -d '${mtls_dir}' ]"
  assertTrue "CRL should be generated on enable" "[ -f '${mtls_dir}/ca.crl' ]"

  assertFileContainsSubstring 'ssl_crl /etc/letsencrypt/mtls/crl.test/ca.crl;' "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"

  local serial_upper
  serial_upper="$(openssl x509 -in "${mtls_dir}/client1.crt" -serial -noout | cut -d= -f2 | tr '[:lower:]' '[:upper:]')"

  run_dockistrate remove-backend-client-cert crl.test client1 >/dev/null
  assertEquals "remove-backend-client-cert should succeed" 0 $?

  local crl_text
  crl_text="$(openssl crl -in "${mtls_dir}/ca.crl" -text -noout)"
  assertStringContains "CRL should contain revoked certificate serial" "$serial_upper" "$crl_text"

  run_dockistrate replace-backend-ca crl.test >/dev/null
  assertEquals "replace-backend-ca should succeed" 0 $?
  assertTrue "CRL should be regenerated after CA replacement" "[ -f '${mtls_dir}/ca.crl' ]"
  crl_text="$(openssl crl -in "${mtls_dir}/ca.crl" -text -noout)"
  if echo "$crl_text" | grep -Fq "$serial_upper"; then
    fail "Replaced CA should not retain revoked serials"
  fi
  assertTrue "Index should reset after CA replacement" "[ ! -s '${mtls_dir}/index.txt' ]"
  assertFileContainsSubstring 'ssl_crl /etc/letsencrypt/mtls/crl.test/ca.crl;' "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
}
