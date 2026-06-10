#!/usr/bin/env bash

test_recreate_nginx_removes_existing_container_with_volumes() {
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for recreate" 0 $?

  cat >"${CONFIG_DIR}/backend_ports.csv" <<'EOF'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,recreate-volumes.test,127.0.0.1:7000,dockistrate-net,,,,,,,,,,,,,,,,,
port,recreate-volumes.test,,,,,18180,7000,http,none,no,off,,off,auto,,,,,,
EOF

  local docker_log_file="${STATE_DIR}/docker_recreate_with_volumes.log"
  rm -f "$docker_log_file"

  local output status
  output="$(
      DOCKER_MOCK_INSPECT_STATUS="running" \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-nginx-config
  )"
  status=$?

  assertEquals "update-nginx-config should succeed" 0 "$status"
  assertStringContains "update output" "Nginx configuration updated." "$output"
  assertTrue "recreate should remove existing nginx with anonymous volumes" \
    "grep -Fq 'subcommand=rm -f -v nginx-proxy' '${docker_log_file}'"
}
