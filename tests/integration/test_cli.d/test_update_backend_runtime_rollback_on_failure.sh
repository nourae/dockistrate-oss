#!/usr/bin/env bash

test_update_backend_runtime_rollback_on_failure() {
  local domain="update-runtime-rollback.test"
  local cname="backend-${domain}"
  local docker_log_file="${STATE_DIR}/docker_update_backend_runtime_rollback.log"
  rm -f "$docker_log_file"

  local output status original_id restored_id restored_status original_proxy_image
  local reload_failure_marker="${STATE_DIR}/update_backend_reload_failed"
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend "$domain" nginx:alpine 18180 http --no-expose 2>&1)"
  status=$?
  assertEquals "setup add-backend should succeed" 0 "$status"
  original_id="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
    bash "${MOCK_BIN_DIR}/docker" inspect -f '{{.Id}}' "$cname")"
  assertEquals "the original container should have a full immutable ID" 64 "${#original_id}"
  original_proxy_image="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
    bash "${MOCK_BIN_DIR}/docker" inspect -f '{{.Config.Image}}' nginx-proxy)"

  : >"$docker_log_file"
  output="$(
    DOCKER_MOCK_RELOAD_FAIL_ONCE_FILE="$reload_failure_marker" \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-backend "$domain" --image hashicorp/http-echo 2>&1
  )"
  status=$?

  assertNotEquals "update-backend recreate should fail when downstream nginx reload fails" 0 "$status"
  assertTrue "the attempted reload should consume the one-shot failure" "[ -f '$reload_failure_marker' ]"
  assertStringContains "update-backend rollback output should mention rollback" "failed. Rolled back." "$output"
  assertTrue "update-backend rollback should rename the original container by immutable ID first" \
    "grep -Eq '^subcommand=rename ${original_id} ${cname}-rollback-[0-9-]+$' '$docker_log_file'"
  assertTrue "update-backend rollback should remove the failed replacement by full ID with anonymous volumes" \
    "grep -Eq '^subcommand=rm -f -v [0-9a-f]{64}$' '$docker_log_file'"
  assertTrue "update-backend rollback should restore the original container name" \
    "grep -Fq 'subcommand=rename ${original_id} ${cname}' '$docker_log_file'"
  assertTrue "update-backend rollback should not use the volume-preserving remove path for the failed replacement" \
    "! grep -Eq '^subcommand=rm -f [0-9a-f]{64}$' '$docker_log_file'"
  assertTrue "update-backend rollback should never remove the original container" \
    "! grep -Eq '^subcommand=rm -f( -v)? ${original_id}$' '$docker_log_file'"
  restored_id="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
    bash "${MOCK_BIN_DIR}/docker" inspect -f '{{.Id}}' "$cname")"
  restored_status="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
    bash "${MOCK_BIN_DIR}/docker" inspect -f '{{.State.Status}}' "$cname")"
  assertEquals "rollback should restore the same original container identity" "$original_id" "$restored_id"
  assertEquals "rollback should restart the original running container" running "$restored_status"
  assertEquals "rollback should restore the original proxy image" "$original_proxy_image" \
    "$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" bash "${MOCK_BIN_DIR}/docker" inspect -f '{{.Config.Image}}' nginx-proxy)"

  assertTrue "backend row should still exist after update-backend rollback" \
    "grep -Fq 'backend,${domain},172.30.0.2:18180,dockistrate-net' '${CONFIG_DIR}/backend_ports.csv'"
}
