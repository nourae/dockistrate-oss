#!/usr/bin/env bash

test_packet_capture_rejects_unresolved_scopes() {
  local capture_subdir="${CAPTURE_DIR}/test_capture_unresolved"
  local docker_log_file="${STATE_DIR}/docker_capture_unresolved.log"
  local state_file="${CONFIG_DIR}/capture_tls_decrypt.state"
  local output="" status=0 scenario=""
  local -a capture_args=()
  rm -rf "$capture_subdir"
  rm -f "$state_file"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed proxy for rejected capture scopes" 0 $?

  for scenario in unknown_scope unknown_option missing_value empty_clients unknown_backend combined_missing_backend; do
    case "$scenario" in
    unknown_scope) capture_args=(--scope clientz) ;;
    unknown_option) capture_args=(--client 198.51.100.10) ;;
    missing_value) capture_args=(--scope) ;;
    empty_clients) capture_args=(--scope clients --clients '') ;;
    unknown_backend) capture_args=(--scope backends --backends missing-capture.example.test) ;;
    combined_missing_backend) capture_args=(--scope clients-backends --clients 198.51.100.10 --backends missing-capture.example.test) ;;
    esac
    : >"$docker_log_file"
    output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" run_dockistrate start-capture \
      pcaps/test_capture_unresolved --tls-decrypt "${capture_args[@]}")"
    status=$?
    assertNotEquals "$scenario must fail instead of widening capture" 0 "$status"
    assertStringContains "$scenario reports a validation error" '[Error]' "$output"
    assertTrue "$scenario does not create the requested capture directory" "[ ! -e '$capture_subdir' ]"
    assertTrue "$scenario does not enable TLS key logging" "[ ! -e '$state_file' ]"
    assertTrue "$scenario does not replace or start the capture container" \
      "! grep -E 'subcommand=(run -d --name nginx-capture|rm -f -v )' '$docker_log_file'"
  done
  rm -f "$docker_log_file"
}
