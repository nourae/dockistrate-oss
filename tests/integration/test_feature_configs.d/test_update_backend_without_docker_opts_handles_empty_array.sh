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
  assertTrue "docker run should be invoked for updated backend container without unbound-array failure" \
    "grep -Fq 'subcommand=run -d --name backend-${domain} --network dockistrate-net hashicorp/http-echo' '${docker_log_file}'"
}
