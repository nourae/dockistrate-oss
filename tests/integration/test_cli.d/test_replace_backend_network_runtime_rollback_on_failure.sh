#!/usr/bin/env bash

# shellcheck source=lib/utils/csv.sh
source "${ROOT_DIR}/lib/utils/csv.sh"

test_replace_backend_network_runtime_rollback_on_failure() {
  run_dockistrate add-backend netrollback.test nginx:alpine 9200 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  local docker_log_file="${STATE_DIR}/docker_replace_backend_network_rollback.log"
  rm -f "$docker_log_file"

  local output status
  output="$(
    DOCKER_MOCK_PS_NAMES=$'backend-netrollback.test\nnginx-proxy' \
      DOCKER_MOCK_PROXY_MANAGED=false \
      DOCKER_MOCK_INSPECT_NETWORK_MAP='custom-net=10.66.0.5' \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate replace-backend-network netrollback.test custom-net 2>&1
  )"
  status=$?

  assertNotEquals "replace-backend-network should fail when downstream update-nginx-config fails" 0 "$status"
  assertStringContains "replace-backend-network failure should report rollback" "failed. Rolled back." "$output"
  assertTrue "replace-backend-network rollback path should produce a docker log" "[ -f '${docker_log_file}' ]"

  local backend_line
  backend_line="$(grep '^backend,netrollback.test,' "${CONFIG_DIR}/backend_ports.csv")"
  if [ -z "$backend_line" ]; then
    fail "Expected backend row for netrollback.test to exist after rollback"
  fi

  local type domain upstream backend_network
  if ! csv_parse_line "$backend_line"; then
    fail "Expected valid CSV backend row for netrollback.test"
    return
  fi
  if [ "$CSV_FIELD_COUNT" -lt 4 ]; then
    fail "Expected backend row for netrollback.test to contain at least 4 fields"
    return
  fi
  type="${CSV_FIELDS[0]-}"
  domain="${CSV_FIELDS[1]-}"
  upstream="${CSV_FIELDS[2]-}"
  backend_network="${CSV_FIELDS[3]-}"
  assertEquals "backend row type after rollback" "backend" "$type"
  assertEquals "backend row domain after rollback" "netrollback.test" "$domain"
  assertEquals "backend row network after rollback" "dockistrate-net" "$backend_network"
  assertEquals "backend upstream after rollback" "127.0.0.1:9200" "$upstream"

  assertTrue "network change should disconnect old network before failure" \
    "grep -Fq 'subcommand=network disconnect dockistrate-net backend-netrollback.test' '$docker_log_file'"
  assertTrue "rollback hook should reconnect old network after failure" \
    "grep -Fq 'subcommand=network connect dockistrate-net backend-netrollback.test' '$docker_log_file'"
}
