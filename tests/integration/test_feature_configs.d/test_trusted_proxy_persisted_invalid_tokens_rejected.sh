#!/usr/bin/env bash

test_trusted_proxy_persisted_invalid_token_rejected() {
  local domain="trusted-proxy-invalid.test"
  local settings_file http_include stream_include backends_conf
  local before_http before_stream before_backends after_http after_stream after_backends
  local output status

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

  cat >"$settings_file" <<EOF_SETTINGS
setting_key,setting_value
TRUSTED_PROXY_RANGES,10.0.0.0/8; return 200;
EOF_SETTINGS

  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail on persisted invalid trusted proxy token" 0 "$status"
  assertStringContains "persisted trusted proxy reason" "Invalid trusted proxy range in persisted global settings: 10.0.0.0/8;" "$output"

  after_http="$(cat "$http_include")"
  after_stream="$(cat "$stream_include")"
  after_backends="$(cat "$backends_conf")"
  assertEquals "http acl include should be rolled back after invalid trusted proxy token" "$before_http" "$after_http"
  assertEquals "stream acl include should be rolled back after invalid trusted proxy token" "$before_stream" "$after_stream"
  assertEquals "backend config should be rolled back after invalid trusted proxy token" "$before_backends" "$after_backends"
}
