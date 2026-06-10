#!/usr/bin/env bash

test_start_nginx_fails_when_container_not_running() {
  unset DOCKER_MOCK_INSPECT_STATUS
  local output
  output="$(run_dockistrate start-nginx)"
  local status=$?
  assertTrue "start-nginx should fail when container is not running" "[ ${status} -ne 0 ]"
  assertStringContains "start-nginx failure message" "[Error] Nginx container failed to start" "$output"
}
