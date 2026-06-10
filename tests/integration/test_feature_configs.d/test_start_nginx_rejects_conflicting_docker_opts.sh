#!/usr/bin/env bash

test_start_nginx_rejects_conflicting_docker_opts() {
  local output status
  output="$(run_dockistrate start-nginx --docker-opts '--publish 18180:80' 2>&1)"
  status=$?

  assertNotEquals "start-nginx should reject conflicting docker opts" 0 "$status"
  assertStringContains "start-nginx guardrail message" "conflicts with published listen ports" "$output"
  assertTrue "global settings should not store rejected nginx docker opts" \
    "! grep -Fq 'NGINX_DOCKER_OPTS,--publish 18180:80' '${CONFIG_DIR}/global_settings.csv'"
}

test_start_nginx_rejects_reserved_proxy_labels_in_docker_opts() {
  local output status
  output="$(run_dockistrate start-nginx --docker-opts '--label com.dockistrate.managed=false' 2>&1)"
  status=$?

  assertNotEquals "start-nginx should reject reserved proxy ownership labels" 0 "$status"
  assertStringContains "start-nginx should explain reserved proxy labels" \
    "reserved for Dockistrate-managed proxy ownership" "$output"
  assertTrue "global settings should not store rejected reserved nginx docker opts" \
    "! grep -Fq 'NGINX_DOCKER_OPTS,--label com.dockistrate.managed=false' '${CONFIG_DIR}/global_settings.csv'"
}
