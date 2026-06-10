#!/usr/bin/env bash

test_default_config_skips_https_without_default_cert() {
  local domain="default-cert-failure.test"
  local listen_port="18443"

  run_dockistrate add-backend "$domain" nginx:alpine 9443 https --listen "$listen_port" >/dev/null
  assertEquals "seed https backend for default-cert failure scenario" 0 $?

  local default_conf="${CONFIG_DIR}/nginx_conf/conf.d/default.conf"
  local cert="${CONFIG_DIR}/nginx_conf/conf.d/default.crt"
  local key="${CONFIG_DIR}/nginx_conf/conf.d/default.key"
  rm -f "$cert" "$key"

  local fake_bin output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    cat <<'EOF'
exit 127
EOF
  } >"${fake_bin}/openssl"
  chmod +x "${fake_bin}/openssl"

  status=0
  output="$(cd "$ROOT_DIR" && PATH="${fake_bin}:${MOCK_BIN_DIR}:$PATH" SKIP_DOCKER_CHECKS=true ./dockistrate.sh update-nginx-config 2>&1)" || status=$?

  rm -rf "$fake_bin"

  assertEquals "update-nginx-config should succeed when openssl fails" 0 "$status"
  assertStringContains "update-nginx-config should warn when default HTTPS fallback is skipped" \
    "skipping default HTTPS listener configuration" "$output"
  assertTrue "default config should still be created when HTTPS is skipped" "[ -f '$default_conf' ]"
  assertTrue "default HTTP listener should remain configured" \
    "grep -Fq 'listen 80 default_server;' '$default_conf'"
  assertFalse "default certificate should not be left behind after openssl failure" "[ -f '$cert' ]"
  assertFalse "default key should not be left behind after openssl failure" "[ -f '$key' ]"
  assertFalse "default 443 HTTPS listener should be skipped without cert" \
    "grep -Fq 'listen 443 ssl default_server;' '$default_conf'"
  assertFalse "extra HTTPS default listener should be skipped without cert" \
    "grep -Fq 'listen ${listen_port} ssl default_server;' '$default_conf'"
  assertFalse "default HTTPS certificate directive should be skipped without cert" \
    "grep -Fq 'ssl_certificate ' '$default_conf'"
  assertFalse "default HTTPS key directive should be skipped without cert" \
    "grep -Fq 'ssl_certificate_key ' '$default_conf'"
}
