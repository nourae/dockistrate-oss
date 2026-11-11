#!/usr/bin/env bash

test_remove_nginx_removes_container_with_volumes() {
  local docker_log_file="${STATE_DIR}/docker_remove_nginx_with_volumes.log"
  rm -f "$docker_log_file"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for remove-nginx" 0 $?
  local original_id
  original_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker inspect -f '{{.Id}}' nginx-proxy)"
  assertEquals "managed proxy has a full immutable identity" 64 "${#original_id}"

  local output
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKISTRATE_NGINX_CONTAINER_NAME="custom-proxy" run_dockistrate remove-nginx)"
  local status=$?

  assertEquals "remove-nginx should succeed" 0 "$status"
  assertStringContains "remove-nginx output" "Removed Nginx container." "$output"
  assertTrue "remove-nginx should remove anonymous volumes with container" \
    "grep -Fq 'subcommand=rm -f -v $original_id' '$docker_log_file'"
  assertFalse "explicit remove-nginx removes the verified proxy with checks skipped" \
    "PATH='${MOCK_BIN_DIR}:$PATH' docker inspect -f '{{.Id}}' '$original_id' >/dev/null 2>&1"
  assertTrue "remove-nginx should ignore removed custom proxy env overrides" \
    "! grep -Fq 'subcommand=rm -f -v custom-proxy' '$docker_log_file'"
}
