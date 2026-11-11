#!/usr/bin/env bash

test_tls_decrypt_capture_context_is_single_line_in_audit_log() {
  rm -f "${LOG_DIR}/audit.log"

  local backend_with_controls expected_fragment output status
  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend capture-context.example.test nginx:alpine 18182 http --listen 18083 >/dev/null
  assertEquals "seed backend for tls context capture" 0 $?
  backend_with_controls="$(printf 'capture-context.example.test\ncapture-context.example.test\tcapture-context.example.test\rcapture-context.example.test')"
  expected_fragment="backends=capture-context.example.test capture-context.example.test capture-context.example.test capture-context.example.test clients=all"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for tls context capture" 0 $?

  output="$(run_dockistrate start-capture pcaps/test_capture_context --tls-decrypt --backends "$backend_with_controls")"
  status=$?
  assertEquals "start-capture with control characters in context should succeed" 0 "$status"
  assertStringContains "warn output should use sanitized single-line context" \
    "$expected_fragment" "$output"
  assertTrue "audit log should include sanitized single-line context" \
    "grep -Fq '${expected_fragment}' '${LOG_DIR}/audit.log'"

  local stop_output stop_status
  stop_output="$(run_dockistrate stop-capture)"
  stop_status=$?
  assertEquals "stop-capture after context sanitization test" 0 "$stop_status"
  assertStringContains "stop-capture message" "Packet capture stopped" "$stop_output"
}
