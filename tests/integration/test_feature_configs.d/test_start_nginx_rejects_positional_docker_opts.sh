#!/usr/bin/env bash

test_start_nginx_rejects_positional_docker_opts() {
  local output status
  output="$(run_dockistrate start-nginx --docker-opts 'alpine' 2>&1)"
  status=$?

  assertNotEquals "start-nginx should reject positional docker opts tokens" 0 "$status"
  assertStringContains "start-nginx positional token guardrail message" "positional token alpine is not allowed" "$output"
  assertTrue "global settings should not store rejected positional nginx docker opts" \
    "! grep -Fq 'NGINX_DOCKER_OPTS,alpine' '${CONFIG_DIR}/global_settings.csv'"
}
