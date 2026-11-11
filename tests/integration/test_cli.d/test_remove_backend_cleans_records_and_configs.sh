#!/usr/bin/env bash

test_remove_backend_cleans_records_and_configs() {
  local docker_log_file="${STATE_DIR}/docker_remove_backend_cleanup.log"
  rm -f "$docker_log_file"

  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend cleanup.test nginx:alpine 7070 http >/dev/null
  assertEquals "seed add-backend" 0 $?
  local original_id
  original_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker inspect -f '{{.Id}}' backend-cleanup.test)"
  assertEquals "managed backend has a full immutable identity" 64 "${#original_id}"

  local remove_output
  remove_output="$(SKIP_DOCKER_CHECKS=false DOCKER_MOCK_LOG_FILE="$docker_log_file" \
    run_dockistrate remove-backend cleanup.test)"
  assertEquals "remove-backend should succeed" 0 $?
  assertStringContains "remove output" "Removed config entries" "$remove_output"
  assertTrue "remove-backend should remove container with anonymous volumes" \
    "grep -Fq 'subcommand=rm -f -v ${original_id}' '$docker_log_file'"

  if [ -f "${CONFIG_DIR}/backend_ports.csv" ]; then
    if grep -q '^backend,cleanup.test,' "${CONFIG_DIR}/backend_ports.csv"; then
      fail "Backend entry for cleanup.test still present in backend_ports.csv"
    fi
  fi

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "empty config marker" "# No backends configured yet." "$conf"
}
