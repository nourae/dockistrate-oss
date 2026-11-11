#!/usr/bin/env bash

test_update_backend_clears_docker_opts() {
  local domain="clear-opts.example.com"
  local cname="backend-${domain}"
  local docker_log_file="${STATE_DIR}/docker_update_backend_clear_opts.log"
  rm -f "$docker_log_file"

  local output status original_id
  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend "$domain" nginx:alpine 18180 http --docker-opts '--label app=seed' --no-expose 2>&1)"
  status=$?
  assertEquals "setup add-backend should succeed" 0 "$status"
  original_id="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
    bash "${MOCK_BIN_DIR}/docker" inspect -f '{{.Id}}' "$cname")"
  assertEquals "the original container should have a full immutable ID" 64 "${#original_id}"

  local opts_file="${CONFIG_DIR}/backend_docker_opts.csv"
  assertTrue "docker opts entry should exist before clear" \
    "grep -Fq '${domain},--label app=seed' '$opts_file'"

  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKER_MOCK_PS_NAMES="$cname" SKIP_DOCKER_CHECKS=false \
    run_dockistrate update-backend "$domain" --image nginx:alpine --docker-opts '' 2>&1)"
  status=$?
  assertEquals "update-backend with empty --docker-opts should succeed" 0 "$status"
  assertStringContains "update-backend output should report backend update" "Backend '${domain}' updated." "$output"

  assertTrue "docker opts entry should be removed after clear" \
    "! grep -q '^${domain},' '$opts_file'"
  assertTrue "update-backend should stage the old container under a rollback name before recreating" \
    "grep -Eq '^subcommand=rename ${original_id} ${cname}-rollback-[0-9-]+$' '${docker_log_file}'"
  assertTrue "update-backend should not delete anonymous volumes during recreate" \
    "! grep -Fq 'subcommand=rm -f -v ${original_id}' '${docker_log_file}'"
  assertTrue "update-backend should remove the old container by ID while preserving its anonymous volumes" \
    "grep -Fxq 'subcommand=rm -f ${original_id}' '${docker_log_file}'"
}
