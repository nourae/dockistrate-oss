#!/usr/bin/env bash

test_start_nginx_rejects_unmanaged_proxy_conflict() {
  local docker_log_file="${STATE_DIR}/docker_start_nginx_conflict.log"
  rm -f "$docker_log_file"
  DOCKER_MOCK_PROXY_MANAGED=false PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name nginx-proxy nginx:1.28.1 >/dev/null

  local output status
  output="$(
    DOCKER_MOCK_PROXY_MANAGED=false \
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
    SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?

  assertNotEquals "start-nginx should fail when nginx-proxy is not Dockistrate-managed" 0 "$status"
  assertStringContains "start-nginx should explain ownership conflict" "not Dockistrate-managed" "$output"
  assertTrue "start-nginx should not recreate or remove an unmanaged proxy" \
    "! grep -Eq 'subcommand=(rm|run) .*nginx-proxy' '${docker_log_file}'"
}

test_start_nginx_rejects_foreign_checkout_proxy_conflict() {
  local docker_log_file="${STATE_DIR}/docker_start_nginx_foreign_conflict.log"
  rm -f "$docker_log_file"
  PATH="${MOCK_BIN_DIR}:$PATH" docker run -d \
    --name nginx-proxy \
    --label com.dockistrate.managed=true \
    --label com.dockistrate.role=proxy \
    --label com.dockistrate.state-dir=/tmp/foreign-dockistrate-state \
    nginx:1.28.1 >/dev/null

  local output status
  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
    SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?

  assertNotEquals "start-nginx should fail when nginx-proxy belongs to another checkout" 0 "$status"
  assertStringContains "start-nginx should explain foreign-checkout conflict" "not Dockistrate-managed by this checkout" "$output"
  assertTrue "start-nginx should not recreate or remove a foreign-checkout proxy" \
    "! grep -Eq 'subcommand=(rm|run) .*nginx-proxy' '${docker_log_file}'"
}
