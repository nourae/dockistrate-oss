#!/usr/bin/env bash

test_set_nginx_docker_opts_save_show_and_clear() {
  local opts='--ulimit nofile=65535:65535 --cpus 1.5'
  local output status

  output="$(run_dockistrate set-nginx-docker-opts "$opts" 2>&1)"
  status=$?
  assertEquals "set-nginx-docker-opts should succeed" 0 "$status"
  assertStringContains "set-nginx-docker-opts output" "NGINX_DOCKER_OPTS set" "$output"
  assertTrue "global settings should persist nginx docker opts" \
    "grep -Fq 'NGINX_DOCKER_OPTS,--ulimit nofile=65535:65535 --cpus 1.5' '${CONFIG_DIR}/global_settings.csv'"

  output="$(run_dockistrate show-nginx-docker-opts 2>&1)"
  status=$?
  assertEquals "show-nginx-docker-opts should succeed" 0 "$status"
  assertEquals "show-nginx-docker-opts should return saved value" "$opts" "$output"

  output="$(run_dockistrate set-nginx-docker-opts '' 2>&1)"
  status=$?
  assertEquals "set-nginx-docker-opts clear should succeed" 0 "$status"
  assertStringContains "clear output" "NGINX_DOCKER_OPTS cleared" "$output"

  output="$(run_dockistrate show-nginx-docker-opts 2>&1)"
  status=$?
  assertEquals "show-nginx-docker-opts after clear should succeed" 0 "$status"
  assertEquals "show-nginx-docker-opts after clear should print [None]" "[None]" "$output"
}

test_set_nginx_docker_opts_rejects_reserved_proxy_labels() {
  local output status
  output="$(run_dockistrate set-nginx-docker-opts '--label com.dockistrate.state-dir=/tmp/foreign' 2>&1)"
  status=$?

  assertNotEquals "set-nginx-docker-opts should reject reserved proxy ownership labels" 0 "$status"
  assertStringContains "set-nginx-docker-opts should explain reserved proxy labels" \
    "reserved for Dockistrate-managed proxy ownership" "$output"
  assertTrue "global settings should not persist rejected reserved nginx docker opts" \
    "! grep -Fq 'NGINX_DOCKER_OPTS,--label com.dockistrate.state-dir=/tmp/foreign' '${CONFIG_DIR}/global_settings.csv'"
}
