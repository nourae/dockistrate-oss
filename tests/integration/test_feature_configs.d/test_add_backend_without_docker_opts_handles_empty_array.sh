#!/usr/bin/env bash

test_add_backend_without_docker_opts_handles_empty_array() {
  local domain="empty-opts.example.com"
  local docker_log_file="${STATE_DIR}/docker_add_backend_empty_opts.log"
  rm -f "$docker_log_file"

  local output status
  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend "$domain" nicolaka/netshoot 80 http --no-expose)"
  status=$?
  assertEquals "add-backend without --docker-opts should succeed under Bash 3 set -u" 0 "$status"
  assertStringContains "add-backend output should report backend creation" "Backend for '${domain}'" "$output"
  assertTrue "docker run should be invoked for backend container without unbound-array failure" \
    "grep -Fq 'subcommand=run -d --name backend-${domain} --network dockistrate-net nicolaka/netshoot' '${docker_log_file}'"
  assertTrue "nginx recreate should handle empty port/tls arrays under Bash 3 set -u" \
    "grep -Fq 'subcommand=run -d --name nginx-proxy' '${docker_log_file}'"
}
