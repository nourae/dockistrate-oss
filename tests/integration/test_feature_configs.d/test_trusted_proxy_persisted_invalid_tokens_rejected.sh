#!/usr/bin/env bash

test_trusted_proxy_persisted_invalid_token_rejected() {
  local domain="trusted-proxy-invalid.test"
  local settings_file http_include stream_include backends_conf
  local before_http before_stream before_backends after_http after_stream after_backends
  local output status before_settings after_settings before_config after_config

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?
  run_dockistrate add-port "$domain" 9000 18180 tcp none >/dev/null
  assertEquals "seed tcp port" 0 $?
  run_dockistrate set-backend-client-ip-header "$domain" X-Client-IP >/dev/null
  assertEquals "seed backend client IP header" 0 $?

  settings_file="${CONFIG_DIR}/global_settings.csv"
  http_include="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/${domain}.inc"
  stream_include="${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/${domain}.inc"
  backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  before_http="$(cat "$http_include")"
  before_stream="$(cat "$stream_include")"
  before_backends="$(cat "$backends_conf")"

  integration_global_csv_set "$settings_file" TRUSTED_PROXY_RANGES '10.0.0.0/8; return 200;'

  before_settings="$(cat "$settings_file")"
  before_config="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail on persisted invalid trusted proxy token" 0 "$status"
  assertStringContains "persisted trusted proxy reason" "Invalid persisted setting TRUSTED_PROXY_RANGES" "$output"

  after_settings="$(cat "$settings_file")"
  after_config="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
  assertEquals "invalid persisted settings should not be rewritten or defaulted" "$before_settings" "$after_settings"
  assertEquals "early rejection must preserve all config files" "$before_config" "$after_config"
  after_http="$(cat "$http_include")"
  after_stream="$(cat "$stream_include")"
  after_backends="$(cat "$backends_conf")"
  assertEquals "http acl include should remain unchanged after early invalid trusted proxy rejection" "$before_http" "$after_http"
  assertEquals "stream acl include should remain unchanged after early invalid trusted proxy rejection" "$before_stream" "$after_stream"
  assertEquals "backend config should remain unchanged after early invalid trusted proxy rejection" "$before_backends" "$after_backends"
}
