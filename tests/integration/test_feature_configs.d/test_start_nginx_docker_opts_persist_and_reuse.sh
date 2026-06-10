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
  assertTrue "global settings should persist nginx docker opts from start-nginx" \
    "grep -Fq 'NGINX_DOCKER_OPTS,--ulimit nofile=65535:65535 --cpus 1.5' '${CONFIG_DIR}/global_settings.csv'"
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

test_start_nginx_rejects_saved_reserved_labels() {
  local docker_log_file="${STATE_DIR}/docker_start_nginx_reserved_labels.log"
  rm -f "$docker_log_file"

  cat >"${CONFIG_DIR}/global_settings.csv" <<EOF
setting_key,setting_value
NGINX_DOCKER_OPTS,--label com.dockistrate.state-dir=/tmp/foreign --cpus 1.5
EOF

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
  assertStringContains "start-nginx should explain saved reserved labels" \
    "reserved for Dockistrate-managed proxy ownership" "$output"
  assertTrue "docker run should not start with tampered saved labels" \
    "! grep -Fq 'subcommand=run -d --name nginx-proxy' '${docker_log_file}'"
}
