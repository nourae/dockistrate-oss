#!/usr/bin/env bash

test_tls_decrypt_capture_ignores_removed_permissive_env() {
  local capture_subdir="${CAPTURE_DIR}/test_capture_tls_permissive"
  local state_file="${CONFIG_DIR}/capture_tls_decrypt.state"
  rm -rf "$capture_subdir"
  rm -f "$state_file"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for tls-decrypt capture" 0 $?

  local output status
  output="$(DOCKISTRATE_TLS_KEYLOG_PERMISSIVE=true SKIP_DOCKER_CHECKS=false \
    run_dockistrate start-capture pcaps/test_capture_tls_permissive --tls-decrypt)"
  status=$?
  assertEquals "tls-decrypt start should succeed when removed permissive env override is present" 0 "$status"
  assertStringContains "tls-decrypt output should mention enabled mode" "tls-decrypt: enabled" "$output"
  assertTrue "tls decrypt state file should exist" "[ -f '${state_file}' ]"

  local keylog_file
  keylog_file="$(awk -F'=' '$1=="keylog_file"{sub(/^keylog_file=/,""); print; exit}' "$state_file")"
  assertTrue "keylog file should be recorded" "[ -n '${keylog_file}' ]"
  assertTrue "keylog file should exist" "[ -f '${keylog_file}' ]"
  assertEquals "keylog directory mode should remain strict when removed permissive env override is present" "700" "$(get_mode "$(dirname "$keylog_file")")"
  assertEquals "keylog file mode should remain strict when removed permissive env override is present" "600" "$(get_mode "$keylog_file")"

  local stop_output stop_status
  stop_output="$(DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate stop-capture)"
  stop_status=$?
  assertEquals "stop-capture should succeed" 0 "$stop_status"
  assertStringContains "stop output should confirm stop" "Packet capture stopped" "$stop_output"
}
