#!/usr/bin/env bash

test_start_nginx_docker_opts_persist_and_reuse() {
  local docker_log_file="${STATE_DIR}/docker_start_nginx_docker_opts.log"
  rm -f "$docker_log_file"

  local opts='--ulimit nofile=65535:65535 --cpus 1.5'
  local output status
  output="$(
    DOCKER_MOCK_PS_NAMES='' \
    DOCKER_MOCK_INSPECT_STATUS=running \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx --docker-opts "$opts" 2>&1
  )"
  status=$?
  assertEquals "start-nginx with docker opts should succeed" 0 "$status"
  assertStringContains "start-nginx output should report running" "Nginx proxy running." "$output"
  assertEquals "global settings should persist nginx docker opts from start-nginx" "--ulimit nofile=65535:65535 --cpus 1.5" \
    "$(integration_global_csv_get "$CONFIG_DIR/global_settings.csv" NGINX_DOCKER_OPTS)"
  assertTrue "docker run should include configured nginx docker opts" \
    "grep -Eq 'subcommand=run -d --name nginx-proxy .*--ulimit nofile=65535:65535 --cpus 1.5' '${docker_log_file}'"

  DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false run_dockistrate remove-nginx >/dev/null
  assertEquals "remove-nginx after seeded start-nginx" 0 $?

  : >"$docker_log_file"

  output="$(
    DOCKER_MOCK_PS_NAMES='' \
    DOCKER_MOCK_INSPECT_STATUS=running \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?
  assertEquals "start-nginx without docker opts should still succeed" 0 "$status"
  assertStringContains "start-nginx output should report running on reuse" "Nginx proxy running." "$output"
  assertTrue "docker run should reuse saved nginx docker opts on later start-nginx runs" \
    "grep -Eq 'subcommand=run -d --name nginx-proxy .*--ulimit nofile=65535:65535 --cpus 1.5' '${docker_log_file}'"
}

test_start_nginx_redacted_policy_hides_saved_docker_opts_message() {
  run_dockistrate set-visibility-policy redacted >/dev/null
  assertEquals "set redacted visibility policy" 0 $?

  local docker_log_file="${STATE_DIR}/docker_start_nginx_redacted_docker_opts.log"
  rm -f "$docker_log_file"

  local opts='--env NGINX_SECRET=hidden --cpus 1'
  local output status
  output="$(
    DOCKER_MOCK_PS_NAMES='' \
    DOCKER_MOCK_INSPECT_STATUS=running \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx --docker-opts "$opts" 2>&1
  )"
  status=$?
  assertEquals "start-nginx with redacted docker opts should succeed" 0 "$status"
  assertStringContains "start-nginx output should report redacted saved opts" \
    "Saved Nginx docker options: [REDACTED]" "$output"
  case "$output" in
  *"NGINX_SECRET=hidden"*)
    fail "start-nginx redacted output leaked saved docker opts: $output"
    ;;
  esac
  assertEquals "global settings should persist full nginx docker opts from redacted start-nginx" "--env NGINX_SECRET=hidden --cpus 1" \
    "$(integration_global_csv_get "$CONFIG_DIR/global_settings.csv" NGINX_DOCKER_OPTS)"
  assertTrue "docker run should still receive full nginx docker opts in redacted mode" \
    "grep -Eq 'subcommand=run -d --name nginx-proxy .*--env NGINX_SECRET=hidden --cpus 1' '${docker_log_file}'"
}

test_start_nginx_rejects_saved_reserved_labels() {
  local docker_log_file="${STATE_DIR}/docker_start_nginx_reserved_labels.log"
  rm -f "$docker_log_file"

  if ! integration_global_csv_set "$CONFIG_DIR/global_settings.csv" NGINX_DOCKER_OPTS \
    '--label com.dockistrate.state-dir=/tmp/foreign --cpus 1.5'; then
    fail "Unable to seed reserved Nginx Docker labels"
    return 1
  fi

  local output status
  output="$(
    DOCKER_MOCK_PS_NAMES='' \
    DOCKER_MOCK_INSPECT_STATUS=running \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?
  assertNotEquals "start-nginx should reject tampered saved reserved labels" 0 "$status"
  assertStringContains "start-nginx should reject saved options during persisted-state validation" \
    "Invalid persisted setting NGINX_DOCKER_OPTS." "$output"
  assertTrue "docker run should not start with tampered saved labels" \
    "! grep -Fq 'subcommand=run -d --name nginx-proxy' '${docker_log_file}'"
}
