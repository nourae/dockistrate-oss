#!/usr/bin/env bash

test_add_backend_custom_network_attaches_nginx() {
  local domain="custom-network-add.test"
  local docker_log_file="${STATE_DIR}/docker_custom_network_add.log"
  rm -f "$docker_log_file"

  local output status
  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate add-backend "$domain" nginx:alpine 18180 http --network custom-net 2>&1
  )"
  status=$?

  assertEquals "add-backend with custom network should succeed" 0 "$status"
  assertStringContains "add-backend output should mention custom network" "on custom-net" "$output"
  assertFileContains "backend,${domain},172.30.0.2:18180,custom-net" "${CONFIG_DIR}/backend_ports.csv"
  assertTrue "Nginx should be connected to the custom backend network" \
    "grep -Fq 'subcommand=network connect custom-net nginx-proxy' '$docker_log_file'"
  assertTrue "backend should be created on the selected custom network" \
    "grep -Fq 'subcommand=run -d --name backend-${domain} --network custom-net nginx:alpine' '$docker_log_file'"
}

test_add_backend_custom_network_rolls_back_when_nginx_attach_fails() {
  local domain="custom-network-fail.test"
  local docker_log_file="${STATE_DIR}/docker_custom_network_fail.log"
  rm -f "$docker_log_file"

  local output status
  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      DOCKER_MOCK_NETWORK_CONNECT_FAIL_FOR="custom-net" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate add-backend "$domain" nginx:alpine 18181 http --network custom-net 2>&1
  )"
  status=$?

  assertNotEquals "add-backend should fail when Nginx cannot join the custom network" 0 "$status"
  assertStringContains "failure output should report Nginx network attachment" "Failed to connect Nginx container 'nginx-proxy' to network 'custom-net'" "$output"
  assertStringContains "failure output should report rollback" "failed. Rolled back." "$output"
  assertTrue "failed add-backend should remove the newly-created backend container" \
    "grep -Fq 'subcommand=rm -f -v backend-${domain}' '$docker_log_file'"
  if [ -f "${CONFIG_DIR}/backend_ports.csv" ] && grep -Fq "backend,${domain}," "${CONFIG_DIR}/backend_ports.csv"; then
    fail "Backend row for ${domain} should not survive failed custom network attach"
  fi
}

test_replace_backend_network_attaches_nginx_to_new_network() {
  local domain="custom-network-replace.test"
  local docker_log_file="${STATE_DIR}/docker_custom_network_replace.log"

  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend "$domain" nginx:alpine 18182 http >/dev/null
  assertEquals "seed add-backend should succeed" 0 $?

  rm -f "$docker_log_file"
  local output status
  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate replace-backend-network "$domain" custom-net 2>&1
  )"
  status=$?

  assertEquals "replace-backend-network should succeed" 0 "$status"
  assertStringContains "replace-backend-network output" "Backend '${domain}' updated." "$output"
  assertFileContains "backend,${domain},172.30.0.2:18182,custom-net" "${CONFIG_DIR}/backend_ports.csv"
  assertTrue "backend should connect to the new custom network" \
    "grep -Fq 'subcommand=network connect custom-net backend-${domain}' '$docker_log_file'"
  assertTrue "backend should disconnect from the old default network" \
    "grep -Fq 'subcommand=network disconnect dockistrate-net backend-${domain}' '$docker_log_file'"
  assertTrue "Nginx should connect to the replacement backend network" \
    "grep -Fq 'subcommand=network connect custom-net nginx-proxy' '$docker_log_file'"
}
