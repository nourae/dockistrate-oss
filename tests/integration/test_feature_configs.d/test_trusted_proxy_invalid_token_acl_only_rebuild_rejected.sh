#!/usr/bin/env bash

test_trusted_proxy_invalid_token_acl_only_rebuild_rejected() {
  local domain="trusted-proxy-acl-only.test"
  local settings_file http_include stream_include output status before_config after_config

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?
  run_dockistrate add-port "$domain" 9000 18180 tcp none >/dev/null
  assertEquals "seed tcp port" 0 $?
  run_dockistrate set-client-ip-header off >/dev/null
  assertEquals "disable global client IP header" 0 $?
  run_dockistrate add-acl "$domain" l7 allow 198.51.100.25 >/dev/null
  assertEquals "seed acl" 0 $?
  run_dockistrate set-acl-policy deny >/dev/null
  assertEquals "set-acl-policy deny" 0 $?

  settings_file="${CONFIG_DIR}/global_settings.csv"
  http_include="${CONFIG_DIR}/nginx_conf/conf.d/security_ip/${domain}.inc"
  stream_include="${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/${domain}.inc"

  integration_global_csv_set "$settings_file" TRUSTED_PROXY_RANGES '10.0.0.0/8; return 200;'

  before_config="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
  output="$(run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should reject invalid trusted proxies even when the client IP header is off" 0 "$status"
  assertStringContains "persisted trusted proxy reason" "Invalid persisted setting TRUSTED_PROXY_RANGES" "$output"
  after_config="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
  assertEquals "early rejection must preserve settings and all generated config files" "$before_config" "$after_config"
  assertFileContainsSubstring 'allow 198.51.100.25;' "$http_include"
  assertFileContainsSubstring 'deny all;' "$http_include"
  assertFileContainsSubstring 'allow 198.51.100.25;' "$stream_include"
  assertFileContainsSubstring 'deny all;' "$stream_include"
}
