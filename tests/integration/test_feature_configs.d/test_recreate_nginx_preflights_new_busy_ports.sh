#!/usr/bin/env bash

test_recreate_nginx_preflights_new_busy_ports() {
  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend preflight-busy.test nginx:alpine 7000 http --no-expose >/dev/null
  assertEquals "seed managed backend before preflighting new proxy listeners" 0 $?
  SKIP_DOCKER_CHECKS=false run_dockistrate stop-nginx >/dev/null
  assertEquals "stop the existing proxy before preflighting ports it no longer holds" 0 $?
  local source_dir
  for source_dir in "$STATE_DIR/domains/preflight-busy.test/config" "$STATE_DIR/domains/preflight-busy.test/runtime/applied"; do
    printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,7000,http,,,no,off,,off,auto\n' >"$source_dir/ports.csv"
  done

  local docker_log_file="${STATE_DIR}/docker_recreate_preflight_busy.log"
  rm -f "$docker_log_file"

  local output status
  output="$(
    DOCKER_MOCK_PORT_BUSY_PORT=18180 \
      DOCKER_MOCK_PORT_BUSY_PID=5555 \
      DOCKER_MOCK_PORT_BUSY_PROC=PreflightApp \
      DOCKER_MOCK_PS_NAMES="nginx-proxy" \
      DOCKER_MOCK_INSPECT_STATUS="" \
      DOCKER_MOCK_INSPECT_HOST_PORTS="18180" \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-nginx-config
  )"
  status=$?

  assertTrue "update-nginx-config should fail when a newly required port is busy" "[ $status -ne 0 ]"
  assertStringContains "busy-port error should include owner details" \
    "[Error] Host tcp port 18180 is already in use by PID 5555 (PreflightApp)." "$output"
  assertStringContains "busy-port error should include dynamic suggestion" \
    "[Info] Suggested free port: 18181." "$output"
  assertTrue "nginx container should not be removed before preflight passes" \
    "! grep -Eq 'subcommand=rm( [^ ]+)* nginx-proxy$' \"${docker_log_file}\""
}
