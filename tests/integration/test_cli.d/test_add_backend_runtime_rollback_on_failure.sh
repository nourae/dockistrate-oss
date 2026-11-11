#!/usr/bin/env bash

test_add_backend_runtime_rollback_on_failure() {
  local domain="add-runtime-rollback.test"
  local cname="backend-${domain}"
  local docker_log_file="${STATE_DIR}/docker_add_backend_runtime_rollback.log"
  rm -f "$docker_log_file"

  local output status
  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      DOCKER_MOCK_PS_NAMES="nginx-proxy" \
      DOCKER_MOCK_PROXY_MANAGED=false \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate add-backend "$domain" nginx:alpine 18180 http --no-expose 2>&1
  )"
  status=$?

  assertNotEquals "add-backend should fail when downstream update-nginx-config rejects the unmanaged proxy" 0 "$status"
  assertStringContains "add-backend rollback output should mention rollback" "failed. Rolled back." "$output"
  assertTrue "add-backend rollback should remove the newly-created container by full ID with anonymous volumes" \
    "grep -Eq '^subcommand=rm -f -v [0-9a-f]{64}$' '$docker_log_file'"
  assertTrue "add-backend rollback should not use the volume-preserving remove path for the failed new container" \
    "! grep -Eq '^subcommand=rm -f [0-9a-f]{64}$' '$docker_log_file'"
  assertFalse "add-backend rollback should leave no container under the attempted backend name" \
    "[ -f '${STATE_DIR}/tmp/.docker_mock/${cname}.meta' ]"

  if [ -f "${CONFIG_DIR}/backend_ports.csv" ] && grep -q "^backend,${domain}," "${CONFIG_DIR}/backend_ports.csv"; then
    fail "Backend row for ${domain} should not survive add-backend rollback"
  fi
}
