#!/usr/bin/env bash

test_mtls_configuration_adds_nginx_directives() {
  run_dockistrate add-backend mtls.test nginx:alpine 9443 https >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate enable-backend-mtls mtls.test client1 >/dev/null
  assertEquals "enable-backend-mtls" 0 $?

  local mtls_line="mtls.test,${CERTS_DIR}/mtls/mtls.test"
  assertFileContains "$mtls_line" "${CONFIG_DIR}/backend_mtls.csv"
  assertFileContainsSubstring 'ssl_client_certificate /etc/letsencrypt/mtls/mtls.test/ca.crt;' "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  assertFileContainsSubstring 'ssl_verify_client on;' "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
}
