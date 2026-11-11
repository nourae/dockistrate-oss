#!/usr/bin/env bash

test_recreate_nginx_removes_existing_container_with_volumes() {
  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend recreate-volumes.test nginx:alpine 7000 http --no-expose >/dev/null
  assertEquals "seed managed backend before changing proxy listeners" 0 $?
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for recreate" 0 $?

  local source_dir
  for source_dir in "$STATE_DIR/domains/recreate-volumes.test/config" "$STATE_DIR/domains/recreate-volumes.test/runtime/applied"; do
    printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,7000,http,,,no,off,,off,auto\n' >"$source_dir/ports.csv"
  done

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
