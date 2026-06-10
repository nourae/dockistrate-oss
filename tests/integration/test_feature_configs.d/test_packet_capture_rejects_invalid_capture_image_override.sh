#!/usr/bin/env bash

test_packet_capture_ignores_removed_capture_image_env() {
  rm -rf "${CAPTURE_DIR}/test_capture_bad_image"
  local docker_log_file
  docker_log_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate.capture.env-ignore.XXXXXX.log")"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for capture image override test" 0 $?

  local output status
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKISTRATE_CAPTURE_IMAGE='invalid@@image' \
    run_dockistrate start-capture pcaps/test_capture_bad_image 2>&1)"
  status=$?

  assertEquals "start-capture should ignore removed capture image env override" 0 "$status"
  assertStringContains "start-capture should still report the pinned capture image" \
    "image: nicolaka/netshoot@sha256:47b907d662d139d1e2f22bfe14f4efca1e3f1feed283572f47c970c780c03b61" "$output"
  assertTrue "docker run should still use the pinned default capture image" \
    "grep -Fq 'nicolaka/netshoot@sha256:47b907d662d139d1e2f22bfe14f4efca1e3f1feed283572f47c970c780c03b61' \"$docker_log_file\""

  rm -rf "${CAPTURE_DIR}/test_capture_bad_image"
  rm -f "$docker_log_file"
}
