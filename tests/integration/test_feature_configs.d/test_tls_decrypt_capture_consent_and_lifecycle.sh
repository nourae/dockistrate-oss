#!/usr/bin/env bash

test_tls_decrypt_capture_consent_and_lifecycle() {
  local capture_subdir="${CAPTURE_DIR}/test_capture_tls"
  local state_file="${CONFIG_DIR}/capture_tls_decrypt.state"
  local docker_log_file="${STATE_DIR}/docker_tls_capture.log"
  local sslkeylog_lib_build_file="${STATE_DIR}/tmp/sslkeyloglib/sslkeylogfile.so"
  local nginx_sslkeylog_lib_path="/usr/local/lib/dockistrate/sslkeylogfile.so"
  rm -rf "$capture_subdir"
  rm -f "$state_file"
  rm -f "$docker_log_file"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for tls-decrypt lifecycle" 0 $?

  local output status
  output="$(run_dockistrate start-capture pcaps/test_capture_tls)"
  status=$?
  assertEquals "start-capture without tls-decrypt" 0 "$status"
  assertTrue "tls decrypt state should not exist without flag" "[ ! -f '${state_file}' ]"

  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate start-capture pcaps/test_capture_tls --tls-decrypt)"
  status=$?
  assertEquals "tls-decrypt should succeed without env acknowledgement" 0 "$status"
  assertStringContains "tls-decrypt success should mention enabled mode" "tls-decrypt: enabled" "$output"
  assertTrue "tls decrypt state file should exist" "[ -f '${state_file}' ]"

  local keylog_file
  keylog_file="$(awk -F'=' '$1=="keylog_file"{sub(/^keylog_file=/,""); print; exit}' "$state_file")"
  assertTrue "keylog file path should be recorded" "[ -n '${keylog_file}' ]"
  assertTrue "keylog file should exist" "[ -f '${keylog_file}' ]"
  assertTrue "recreate should set SSLKEYLOGFILE env when tls-decrypt is enabled" \
    "grep -Fq 'SSLKEYLOGFILE=' '${docker_log_file}'"
  assertTrue "recreate should set LIBSSL_SSLKEYLOGFILE env when tls-decrypt is enabled" \
    "grep -Fq 'LIBSSL_SSLKEYLOGFILE=' '${docker_log_file}'"
  assertTrue "recreate should set LD_PRELOAD env when tls-decrypt is enabled" \
    "grep -Fq 'LD_PRELOAD=' '${docker_log_file}'"
  assertTrue "recreate should mount the TLS keylog helper read-only" \
    "grep -Fq '${sslkeylog_lib_build_file}:${nginx_sslkeylog_lib_path}:ro' '${docker_log_file}'"
  assertTrue "TLS keylog helper should be built before nginx recreation" "[ -s '${sslkeylog_lib_build_file}' ]"
  assertEquals "keylog directory mode should be 700 by default" "700" "$(get_mode "$(dirname "$keylog_file")")"
  assertEquals "keylog file mode should be 600 by default" "600" "$(get_mode "$keylog_file")"

  local stop_output stop_status
  stop_output="$(DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate stop-capture)"
  stop_status=$?
  assertEquals "stop-capture should succeed" 0 "$stop_status"
  assertStringContains "stop-capture should confirm tls decrypt disable" \
    "TLS decrypt capture mode disabled" "$stop_output"
  assertStringContains "stop-capture should report preserved key log path" \
    "TLS key log preserved at:" "$stop_output"
  assertStringContains "stop-capture should warn when key log is empty" \
    "TLS key log file is empty" "$stop_output"
  assertTrue "tls decrypt state file should be removed after stop-capture" "[ ! -f '${state_file}' ]"
  assertTrue "keylog file should remain for post-capture analysis" "[ -f '${keylog_file}' ]"
  assertTrue "audit log should include tls decrypt acknowledgement" \
    "grep -Fq 'tls_decrypt acknowledged context=' '${LOG_DIR}/audit.log'"
  assertTrue "audit log should include tls decrypt enable event" \
    "grep -Fq 'tls_decrypt state_change action=enabled' '${LOG_DIR}/audit.log'"
  assertTrue "audit log should include tls decrypt disable event" \
    "grep -Fq 'tls_decrypt state_change action=disabled' '${LOG_DIR}/audit.log'"
}
