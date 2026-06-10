#!/usr/bin/env bash

test_start_nginx_ignores_custom_name_env() {
  local docker_log_file="${STATE_DIR}/docker_start_nginx_ignores_custom_name_env.log"
  rm -f "$docker_log_file"

  local output status
  output="$(
    DOCKER_MOCK_PS_NAMES='' \
    DOCKER_MOCK_INSPECT_STATUS=running \
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
    DOCKISTRATE_NGINX_CONTAINER_NAME="custom-proxy" \
    SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?

  assertEquals "start-nginx should succeed" 0 "$status"
  assertStringContains "start-nginx output should report running" "Nginx proxy running." "$output"
  assertTrue "start-nginx should use the fixed proxy name" \
    "grep -Fq 'subcommand=run -d --name nginx-proxy' '${docker_log_file}'"
  assertTrue "start-nginx should ignore removed custom proxy env overrides" \
    "! grep -Fq 'subcommand=run -d --name custom-proxy' '${docker_log_file}'"
}
