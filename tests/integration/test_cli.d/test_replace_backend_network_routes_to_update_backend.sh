#!/usr/bin/env bash

# shellcheck source=lib/utils/csv.sh
source "${ROOT_DIR}/lib/utils/csv.sh"

test_replace_backend_network_routes_to_update_backend() {
  run_dockistrate add-backend netalias.test nginx:alpine 9100 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  local output
  local docker_log_file="${STATE_DIR}/docker_replace_backend_network.log"
  rm -f "$docker_log_file"
  output="$(
    DOCKER_MOCK_PS_NAMES='backend-netalias.test' \
      DOCKER_MOCK_INSPECT_NETWORK_IP='10.55.0.5' \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_UPDATE_NGINX_CONFIG=true \
      run_dockistrate replace-backend-network netalias.test custom-net
  )"
  assertEquals "replace-backend-network should succeed" 0 $?
  assertStringContains "replace-backend-network output" "Backend 'netalias.test' updated." "$output"
  assertTrue "replace-backend-network should produce a docker log" "[ -f '${docker_log_file}' ]"

  local docker_log
  docker_log="$(cat "$docker_log_file")"
  assertStringContains "replace-backend-network should use safe inspect template for network lookup" 'if eq $k "custom-net"' "$docker_log"
  if printf '%s\n' "$docker_log" | grep -Fq '.NetworkSettings.Networks.custom-net.IPAddress'; then
    fail "replace-backend-network should not use unsafe dot-lookup for hyphenated networks"
  fi

  local backend_line
  backend_line="$(grep '^backend,netalias.test,' "${CONFIG_DIR}/backend_ports.csv")"
  if [ -z "$backend_line" ]; then
    fail "Expected backend row for netalias.test to exist"
  fi

  local type domain upstream backend_network
  if ! csv_parse_line "$backend_line"; then
    fail "Expected valid CSV backend row for netalias.test"
    return
  fi
  if [ "$CSV_FIELD_COUNT" -lt 4 ]; then
    fail "Expected backend row for netalias.test to contain at least 4 fields"
    return
  fi
  type="${CSV_FIELDS[0]-}"
  domain="${CSV_FIELDS[1]-}"
  upstream="${CSV_FIELDS[2]-}"
  backend_network="${CSV_FIELDS[3]-}"
  assertEquals "backend row type" "backend" "$type"
  assertEquals "backend row domain" "netalias.test" "$domain"
  assertEquals "backend row network" "custom-net" "$backend_network"
  if [[ "$upstream" != "10.55.0.5:9100" ]]; then
    fail "Expected upstream to be 10.55.0.5:9100 but was $upstream"
  fi
}
