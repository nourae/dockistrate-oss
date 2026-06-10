#!/usr/bin/env bash

test_packet_capture_rejects_path_escape_outside_capture_root() {
  local output status
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for capture traversal checks" 0 $?

  output="$(run_dockistrate start-capture pcaps/../../escape)"
  status=$?
  assertNotEquals "start-capture should reject traversal outside CAPTURE_DIR" 0 "$status"
  assertStringContains "traversal error should mention capture root containment" \
    "must reside within '${CAPTURE_DIR}'" "$output"

  output="$(run_dockistrate start-capture /tmp/dockistrate-capture-outside)"
  status=$?
  assertNotEquals "start-capture should reject absolute path outside CAPTURE_DIR" 0 "$status"
  assertStringContains "absolute path error should mention capture root containment" \
    "must reside within '${CAPTURE_DIR}'" "$output"
}
