#!/usr/bin/env bash

test_uninstall_all_rejects_unmanaged_proxy_conflict() {
  local docker_log_file="${STATE_DIR}/docker_uninstall_all_conflict.log"
  rm -f "$docker_log_file"

  run_dockistrate add-backend uninstall-conflict.test nginx:alpine 18180 http --no-expose >/dev/null
  assertEquals "seed add-backend" 0 $?
  assertTrue "backend_ports.csv should exist before uninstall-all conflict" "[ -f '${CONFIG_DIR}/backend_ports.csv' ]"

  local output
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKER_MOCK_PS_NAMES="nginx-proxy" DOCKER_MOCK_PROXY_MANAGED=false run_dockistrate uninstall-all)"
  local status=$?

  assertNotEquals "uninstall-all should fail when nginx-proxy is not Dockistrate-managed" 0 "$status"
  assertStringContains "uninstall-all should explain ownership conflict" "not Dockistrate-managed" "$output"
  assertTrue "uninstall-all should leave backend state intact on conflict" "[ -f '${CONFIG_DIR}/backend_ports.csv' ]"
  assertTrue "uninstall-all should not remove the unmanaged proxy" \
    "! grep -Fq 'subcommand=rm -f -v nginx-proxy' '$docker_log_file'"
  assertTrue "uninstall-all should not remove managed backend containers after a proxy conflict" \
    "! grep -Fq 'backend-uninstall-conflict.test' '$docker_log_file'"
}

test_uninstall_all_rejects_foreign_checkout_proxy_conflict() {
  local docker_log_file="${STATE_DIR}/docker_uninstall_all_foreign_conflict.log"
  rm -f "$docker_log_file"

  run_dockistrate add-backend uninstall-foreign-conflict.test nginx:alpine 18180 http --no-expose >/dev/null
  assertEquals "seed add-backend" 0 $?
  PATH="${MOCK_BIN_DIR}:$PATH" docker run -d \
    --name nginx-proxy \
    --label com.dockistrate.managed=true \
    --label com.dockistrate.role=proxy \
    --label com.dockistrate.state-dir=/tmp/foreign-dockistrate-state \
    nginx:1.28.1 >/dev/null

  local output
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" run_dockistrate uninstall-all)"
  local status=$?

  assertNotEquals "uninstall-all should fail when nginx-proxy belongs to another checkout" 0 "$status"
  assertStringContains "uninstall-all should explain foreign-checkout conflict" "not Dockistrate-managed by this checkout" "$output"
  assertTrue "uninstall-all should leave backend state intact on foreign-checkout conflict" "[ -f '${CONFIG_DIR}/backend_ports.csv' ]"
  assertTrue "uninstall-all should not remove the foreign-checkout proxy" \
    "! grep -Fq 'subcommand=rm -f -v nginx-proxy' '$docker_log_file'"
  assertTrue "uninstall-all should not remove managed backend containers after a foreign-checkout proxy conflict" \
    "! grep -Fq 'backend-uninstall-foreign-conflict.test' '$docker_log_file'"
}
