#!/usr/bin/env bash

test_add_backend_rejects_positional_docker_opts() {
  local domain="docker-opts-positional.test"
  local output status
  output="$(run_dockistrate add-backend "$domain" nginx:alpine 18180 http --docker-opts 'alpine' 2>&1)"
  status=$?

  assertNotEquals "add-backend should reject positional docker opts tokens" 0 "$status"
  assertStringContains "add-backend positional token guardrail message" "positional token alpine is not allowed" "$output"

  assertTrue "backend_ports.csv should not contain backend row after rejected add-backend" \
    "! grep -q '^backend,${domain},' '${CONFIG_DIR}/backend_ports.csv'"
  assertTrue "backend_docker_opts.csv should not contain rejected row" \
    "! grep -q '^backend:${domain},' '${CONFIG_DIR}/backend_docker_opts.csv'"
}
