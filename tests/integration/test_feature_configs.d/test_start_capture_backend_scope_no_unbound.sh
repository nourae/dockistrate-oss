#!/usr/bin/env bash

test_start_capture_backend_scope_no_unbound() {
  local domain="capture-backend-no-unbound.test"
  local docker_log_file="${STATE_DIR}/docker_capture_backend_scope.log"
  rm -f "$docker_log_file"
  rm -rf "${CAPTURE_DIR}/test_capture_backend_scope"

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http --listen 18081 >/dev/null
  assertEquals "seed backend for backend-scoped capture" 0 $?
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for backend-scoped capture" 0 $?

  local output status
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" \
    run_dockistrate start-capture pcaps/test_capture_backend_scope --scope backends --backends "$domain")"
  status=$?
  assertEquals "start-capture backend scope should succeed" 0 "$status"
  assertStringContains "start-capture backend scope message" "Packet capture started" "$output"
  assertTrue "start-capture backend scope should not fail with unbound variable" \
    "[[ \"$output\" != *\"unbound variable\"* ]]"
  assertTrue "start-capture backend scope should launch capture container" \
    "grep -Fq 'subcommand=run -d --name nginx-capture' '${docker_log_file}'"

  local stop_output stop_status
  stop_output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate stop-capture)"
  stop_status=$?
  assertEquals "stop-capture after backend-scoped capture" 0 "$stop_status"
  assertStringContains "stop-capture message" "Packet capture stopped" "$stop_output"

  rm -rf "${CAPTURE_DIR}/test_capture_backend_scope"
}
