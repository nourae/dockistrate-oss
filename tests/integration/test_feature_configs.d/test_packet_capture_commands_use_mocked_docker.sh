#!/usr/bin/env bash

test_packet_capture_commands_use_mocked_docker() {
  rm -rf "${CAPTURE_DIR}/test_capture"
  local docker_log_file
  docker_log_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate.capture.default-image.XXXXXX.log")"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for capture command test" 0 $?

  local output
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" run_dockistrate start-capture pcaps/test_capture)"
  local status=$?
  assertEquals "start-capture" 0 "$status"
  assertStringContains "start-capture message" "Packet capture started" "$output"
  assertStringContains "start-capture path" "pcaps/test_capture" "$output"
  assertStringContains "start-capture output should include pinned default capture image" \
    "image: nicolaka/netshoot@sha256:47b907d662d139d1e2f22bfe14f4efca1e3f1feed283572f47c970c780c03b61" "$output"
  assertTrue "docker run should use pinned default capture image" \
    "grep -Fq 'nicolaka/netshoot@sha256:47b907d662d139d1e2f22bfe14f4efca1e3f1feed283572f47c970c780c03b61' '$docker_log_file'"
  assertTrue "start-capture should pre-clean capture container with anonymous volumes" \
    "grep -Fq 'subcommand=rm -f -v nginx-capture' '$docker_log_file'"
  assertTrue "capture directory created" "[ -d '${CAPTURE_DIR}/test_capture' ]"

  # Reset docker mock log so stop-capture assertions cannot match start-capture entries.
  : >"$docker_log_file"

  local stop_output
  stop_output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate stop-capture)"
  local stop_status=$?
  assertEquals "stop-capture" 0 "$stop_status"
  assertStringContains "stop-capture message" "Packet capture stopped" "$stop_output"
  assertTrue "stop-capture should stop capture container" \
    "grep -Fq 'subcommand=stop nginx-capture' '$docker_log_file'"
  assertTrue "stop-capture should remove capture container with anonymous volumes" \
    "grep -Fq 'subcommand=rm -f -v nginx-capture' '$docker_log_file'"
  assertEquals "stop-capture should remove capture container exactly once" "1" \
    "$(grep -F -c 'subcommand=rm -f -v nginx-capture' "$docker_log_file")"

  rm -rf "${CAPTURE_DIR}/test_capture"
  rm -f "$docker_log_file"
}
