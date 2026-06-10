#!/usr/bin/env bash

test_packet_capture_rejects_invalid_client_filters() {
  rm -rf "${CAPTURE_DIR}/test_capture_invalid_clients"
  local docker_log_file
  docker_log_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate.capture.invalid-clients.XXXXXX.log")"
  local state_file="${CONFIG_DIR}/capture_tls_decrypt.state"
  rm -f "$state_file"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for invalid client filter capture" 0 $?

  local output status
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" run_dockistrate start-capture \
    pcaps/test_capture_invalid_clients --scope clients --clients "1.2.3.4 or port 22" --tls-decrypt)"
  status=$?

  assertNotEquals "start-capture should fail for invalid --clients token" 0 "$status"
  assertStringContains "invalid client filter error" "Invalid client IP filter token: 'or'" "$output"
  assertTrue "invalid --clients input should not start capture container" \
    "! grep -Fq 'subcommand=run -d --name nginx-capture' '$docker_log_file'"
  assertTrue "invalid --clients input should not create tls decrypt state" "[ ! -f '${state_file}' ]"
  assertTrue "invalid --clients input should not audit tls decrypt enablement" \
    "! grep -Fq 'tls_decrypt state_change action=enabled' '${LOG_DIR}/audit.log'"

  rm -rf "${CAPTURE_DIR}/test_capture_invalid_clients"
  rm -f "$docker_log_file"
}
