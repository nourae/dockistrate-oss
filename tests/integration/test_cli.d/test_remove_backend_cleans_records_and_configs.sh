#!/usr/bin/env bash

test_remove_backend_cleans_records_and_configs() {
  local docker_log_file="${STATE_DIR}/docker_remove_backend_cleanup.log"
  rm -f "$docker_log_file"

  run_dockistrate add-backend cleanup.test nginx:alpine 7070 http >/dev/null
  assertEquals "seed add-backend" 0 $?
  PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name backend-cleanup.test nginx:alpine >/dev/null

  local remove_output
  remove_output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" \
    run_dockistrate remove-backend cleanup.test)"
  assertEquals "remove-backend should succeed" 0 $?
  assertStringContains "remove output" "Removed config entries" "$remove_output"
  assertTrue "remove-backend should remove container with anonymous volumes" \
    "grep -Fq 'subcommand=rm -f -v backend-cleanup.test' '$docker_log_file'"

  if [ -f "${CONFIG_DIR}/backend_ports.csv" ]; then
    if grep -q '^backend,cleanup.test,' "${CONFIG_DIR}/backend_ports.csv"; then
      fail "Backend entry for cleanup.test still present in backend_ports.csv"
    fi
  fi

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "empty config marker" "# No backends configured yet." "$conf"
}
