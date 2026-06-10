#!/usr/bin/env bash

test_start_nginx_rejects_missing_value_docker_opts() {
  local output status
  output="$(run_dockistrate start-nginx --docker-opts '--cpus' 2>&1)"
  status=$?

  assertNotEquals "start-nginx should reject docker opts missing required values" 0 "$status"
  assertStringContains "start-nginx missing-value guardrail message" "requires a value" "$output"
  assertTrue "global settings should not store rejected missing-value nginx docker opts" \
    "! grep -Fq 'NGINX_DOCKER_OPTS,--cpus' '${CONFIG_DIR}/global_settings.csv'"
}
