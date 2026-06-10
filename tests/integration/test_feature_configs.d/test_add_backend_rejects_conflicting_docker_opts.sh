#!/usr/bin/env bash

test_add_backend_rejects_conflicting_docker_opts() {
  local domain="docker-opts-conflict.test"
  local output status
  output="$(run_dockistrate add-backend "$domain" nginx:alpine 18180 http --docker-opts '--name blocked-backend' 2>&1)"
  status=$?

  assertNotEquals "add-backend should reject conflicting docker opts" 0 "$status"
  assertStringContains "add-backend guardrail message" "conflicts with backend container naming" "$output"

  assertTrue "backend_ports.csv should not contain backend row after rejected add-backend" \
    "! grep -q '^backend,${domain},' '${CONFIG_DIR}/backend_ports.csv'"
  assertTrue "backend_docker_opts.csv should not contain rejected row" \
    "! grep -q '^backend:${domain},' '${CONFIG_DIR}/backend_docker_opts.csv'"
}
