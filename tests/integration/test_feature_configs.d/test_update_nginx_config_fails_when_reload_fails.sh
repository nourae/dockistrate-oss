#!/usr/bin/env bash

test_update_nginx_config_fails_when_reload_fails() {
  run_dockistrate add-backend reload-fail.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for reload failure" 0 $?

  local output status
  output="$(DOCKER_MOCK_PORT_BINDINGS='80/tcp -> 0.0.0.0:80' DOCKER_MOCK_EXEC_FAIL=true SKIP_DOCKER_CHECKS=false \
    run_dockistrate update-nginx-config 2>&1)"
  status=$?

  assertNotEquals "update-nginx-config should fail when nginx reload fails" 0 "$status"
  assertStringContains "reload failure should be visible in output" "Nginx reload failed after config update" "$output"
}
