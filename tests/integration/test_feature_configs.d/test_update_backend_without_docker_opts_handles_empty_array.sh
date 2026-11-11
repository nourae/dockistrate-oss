#!/usr/bin/env bash

test_update_backend_without_docker_opts_handles_empty_array() {
  local domain="update-empty-opts.example.com"
  local docker_log_file="${STATE_DIR}/docker_update_backend_empty_opts.log"
  rm -f "$docker_log_file"

  local output status
  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend "$domain" nicolaka/netshoot 80 http --no-expose)"
  status=$?
  assertEquals "setup add-backend should succeed" 0 "$status"

  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate update-backend "$domain" --image hashicorp/http-echo)"
  status=$?
  assertEquals "update-backend image change without --docker-opts should succeed under Bash 3 set -u" 0 "$status"
  assertStringContains "update-backend output should report backend update" "Backend '${domain}' updated." "$output"
  local ownership_token run_line physical_state_dir
  physical_state_dir="$(cd "$STATE_DIR" && pwd -P)"
  ownership_token="$(awk -F, -v domain="$domain" '$1 == domain {print $3}' "${CONFIG_DIR}/backend_identity.csv")"
  assertTrue "saved backend ownership token should contain 32 lowercase hex characters" \
    "[[ '$ownership_token' =~ ^[0-9a-f]{32}$ ]]"
  run_line="$(grep -F "subcommand=run -d --name backend-${domain} " "$docker_log_file" | tail -n 1)"
  assertEquals "docker run should be invoked for updated backend container without unbound-array failure" \
    "subcommand=run -d --name backend-${domain} --network dockistrate-net --label com.dockistrate.managed=true --label com.dockistrate.role=backend --label com.dockistrate.state-dir=${physical_state_dir} --label com.dockistrate.backend-domain=${domain} --label com.dockistrate.backend-launch=${ownership_token} hashicorp/http-echo" \
    "$run_line"
}
