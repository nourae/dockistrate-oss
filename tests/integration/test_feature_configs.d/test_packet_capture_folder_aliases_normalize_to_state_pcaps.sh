#!/usr/bin/env bash

test_packet_capture_folder_aliases_normalize_to_state_pcaps() {
  rm -rf "${CAPTURE_DIR}/test_capture_alias" "${CAPTURE_DIR}/state"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for capture alias normalization" 0 $?

  local output status
  output="$(run_dockistrate start-capture state/pcaps/test_capture_alias)"
  status=$?
  assertEquals "start-capture with state/pcaps alias" 0 "$status"
  local expected_capture_root=""
  expected_capture_root="$(cd "$CAPTURE_DIR" && pwd)"
  assertStringContains "start-capture output path" "${expected_capture_root}/test_capture_alias" "$output"
  assertTrue "capture directory created in canonical location" "[ -d '${CAPTURE_DIR}/test_capture_alias' ]"
  assertFalse "nested state/pcaps directory should not be created under CAPTURE_DIR" "[ -d '${CAPTURE_DIR}/state/pcaps' ]"
  assertFalse "output should not contain duplicated state/pcaps path" "printf '%s' \"$output\" | grep -Fq '/state/pcaps/state/pcaps/'"

  local stop_output stop_status
  stop_output="$(DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate stop-capture)"
  stop_status=$?
  assertEquals "stop-capture after alias capture" 0 "$stop_status"
  assertStringContains "stop-capture message" "Packet capture stopped" "$stop_output"

  rm -rf "${CAPTURE_DIR}/test_capture_alias" "${CAPTURE_DIR}/state"
}
