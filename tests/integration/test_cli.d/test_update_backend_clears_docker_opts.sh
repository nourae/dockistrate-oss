#!/usr/bin/env bash

test_update_backend_clears_docker_opts() {
  local domain="clear-opts.example.com"
  local cname="backend-${domain}"
  local docker_log_file="${STATE_DIR}/docker_update_backend_clear_opts.log"
  rm -f "$docker_log_file"

  local output status
  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend "$domain" nginx:alpine 18180 http --docker-opts '--label app=seed' --no-expose 2>&1)"
  status=$?
  assertEquals "setup add-backend should succeed" 0 "$status"

  local opts_file="${CONFIG_DIR}/backend_docker_opts.csv"
  assertTrue "docker opts entry should exist before clear" \
    "grep -Fq 'backend:${domain},--label app=seed' '$opts_file'"

  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKER_MOCK_PS_NAMES="$cname" SKIP_DOCKER_CHECKS=false \
    run_dockistrate update-backend "$domain" --image nginx:alpine --docker-opts '' 2>&1)"
  status=$?
  assertEquals "update-backend with empty --docker-opts should succeed" 0 "$status"
  assertStringContains "update-backend output should report backend update" "Backend '${domain}' updated." "$output"

  assertTrue "docker opts entry should be removed after clear" \
    "! grep -q '^backend:${domain},' '$opts_file'"
  assertTrue "update-backend should stage the old container under a rollback name before recreating" \
    "grep -Eq 'subcommand=rename ${cname} ${cname}-rollback-[0-9-]+' '${docker_log_file}'"
  assertTrue "update-backend should not delete anonymous volumes during recreate" \
    "! grep -Fq 'subcommand=rm -f -v ${cname}' '${docker_log_file}'"
}
