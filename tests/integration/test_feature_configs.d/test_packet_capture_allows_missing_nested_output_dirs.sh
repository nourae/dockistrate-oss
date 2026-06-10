#!/usr/bin/env bash

test_packet_capture_allows_missing_nested_output_dirs() {
  local nested_rel="pcaps/new_nested_capture/deep/path"
  local nested_abs="${CAPTURE_DIR}/new_nested_capture/deep/path"
  rm -rf "${CAPTURE_DIR}/new_nested_capture"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for nested capture path" 0 $?

  local output status
  output="$(run_dockistrate start-capture "$nested_rel")"
  status=$?
  assertEquals "start-capture should create missing nested output directories" 0 "$status"
  assertTrue "nested output directory should be created under capture root" "[ -d '${nested_abs}' ]"
  assertStringContains "start-capture output should point to requested nested directory" \
    "/pcaps/new_nested_capture/deep/path/" "$output"

  local stop_output stop_status
  stop_output="$(DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate stop-capture)"
  stop_status=$?
  assertEquals "stop-capture should succeed after nested output capture" 0 "$stop_status"
  assertStringContains "stop-capture message" "Packet capture stopped" "$stop_output"

  rm -rf "${CAPTURE_DIR}/new_nested_capture"
}
