#!/usr/bin/env bash

test_start_nginx_rejects_missing_value_docker_opts() {
  local output status
  output="$(run_dockistrate start-nginx --docker-opts '--cpus' 2>&1)"
  status=$?

  assertNotEquals "start-nginx should reject docker opts missing required values" 0 "$status"
  assertStringContains "start-nginx missing-value guardrail message" "requires a value" "$output"
  assertEquals "global settings should not store rejected missing-value nginx docker opts" "" \
    "$(integration_global_csv_get "$CONFIG_DIR/global_settings.csv" NGINX_DOCKER_OPTS)"
}
