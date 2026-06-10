#!/usr/bin/env bash

test_recreate_nginx_preflights_new_busy_ports() {
  cat >"${CONFIG_DIR}/backend_ports.csv" <<'EOF'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,preflight-busy.test,127.0.0.1:7000,dockistrate-net,,,,,,,,,,,,,,,,,
port,preflight-busy.test,,,,,18180,7000,http,none,no,off,,off,auto,,,,,,
EOF

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
