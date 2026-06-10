#!/usr/bin/env bash

test_update_backend_runtime_rollback_on_failure() {
  local domain="update-runtime-rollback.test"
  local cname="backend-${domain}"
  local docker_log_file="${STATE_DIR}/docker_update_backend_runtime_rollback.log"
  rm -f "$docker_log_file"

  local output status
  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend "$domain" nginx:alpine 18180 http --no-expose 2>&1)"
  status=$?
  assertEquals "setup add-backend should succeed" 0 "$status"

  printf 'weird,%s,172.30.0.2:18180,dockistrate-net,,,,,,,,,,,,,,,,,\n' "$domain" >>"${CONFIG_DIR}/backend_ports.csv"

  : >"$docker_log_file"
  output="$(
    DOCKER_MOCK_INSPECT_STATUS=running \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate update-backend "$domain" --image hashicorp/http-echo 2>&1
  )"
  status=$?

  assertNotEquals "update-backend recreate should fail when downstream update-nginx-config rejects the tampered backend state" 0 "$status"
  assertStringContains "update-backend rollback output should mention rollback" "failed. Rolled back." "$output"
  assertTrue "update-backend rollback should rename the original container out of the way first" \
    "grep -Eq 'subcommand=rename ${cname} ${cname}-rollback-[0-9-]+' '$docker_log_file'"
  assertTrue "update-backend rollback should remove the failed replacement with anonymous volumes" \
    "grep -Fq 'subcommand=rm -f -v ${cname}' '$docker_log_file'"
  assertTrue "update-backend rollback should restore the original container name" \
    "grep -Eq 'subcommand=rename ${cname}-rollback-[0-9-]+ ${cname}' '$docker_log_file'"
  assertTrue "update-backend rollback should not use the volume-preserving remove path for the failed replacement" \
    "! grep -Fq 'subcommand=rm -f ${cname}' '$docker_log_file'"

  assertTrue "backend row should still exist after update-backend rollback" \
    "grep -Fq 'backend,${domain},172.30.0.2:18180,dockistrate-net' '${CONFIG_DIR}/backend_ports.csv'"
}
