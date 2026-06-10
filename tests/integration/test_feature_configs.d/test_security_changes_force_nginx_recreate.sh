#!/usr/bin/env bash

test_security_changes_force_nginx_recreate_and_readiness_check() {
  local domain="security-force-recreate.test"
  local docker_log_file="${STATE_DIR}/docker_security_force_recreate.log"
  local output status

  rm -rf "${STATE_DIR}/tmp/.docker_mock"
  rm -f "$docker_log_file"

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      DOCKER_MOCK_PS_NAMES='' \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?
  assertEquals "start managed nginx" 0 "$status"
  assertStringContains "start-nginx output" "Nginx proxy running." "$output"

  : >"$docker_log_file"

  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate set-acl-policy deny 2>&1
  )"
  status=$?
  assertEquals "set-acl-policy deny should succeed" 0 "$status"
  assertTrue "security policy change should force nginx recreate" \
    "grep -Fq 'subcommand=run -d --name nginx-proxy' '${docker_log_file}'"
  assertTrue "security policy change should run blocking nginx readiness check" \
    "grep -Fq 'subcommand=exec nginx-proxy nginx -t -c /etc/nginx/dockistrate/nginx.conf' '${docker_log_file}'"
}

test_security_change_readiness_failure_rolls_back_state() {
  local domain="security-readiness-rollback.test"
  local docker_log_file="${STATE_DIR}/docker_security_readiness_rollback.log"
  local output status

  rm -rf "${STATE_DIR}/tmp/.docker_mock"
  rm -f "$docker_log_file"

  run_dockistrate add-backend "$domain" nginx:alpine 18181 http >/dev/null
  assertEquals "seed backend" 0 $?

  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      DOCKER_MOCK_PS_NAMES='' \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?
  assertEquals "start managed nginx" 0 "$status"
  assertStringContains "start-nginx output" "Nginx proxy running." "$output"

  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate set-acl-policy allow 2>&1
  )"
  status=$?
  assertEquals "seed ACL allow policy" 0 "$status"

  output="$(
    DOCKER_MOCK_EXEC_FAIL=true \
      DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS=1 \
      DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate set-acl-policy deny 2>&1
  )"
  status=$?
  assertNotEquals "set-acl-policy deny should fail when readiness check fails" 0 "$status"
  assertStringContains "readiness failure should be visible" \
    "Nginx did not pass config readiness checks after security config update." "$output"
  assertFileContainsSubstring "ACL_POLICY,allow" "${CONFIG_DIR}/global_settings.csv"
}

test_deferred_security_update_recreates_on_final_nginx_update() {
  local domain="security-deferred-remove.test"
  local docker_log_file="${STATE_DIR}/docker_security_deferred_remove.log"
  local output status

  rm -rf "${STATE_DIR}/tmp/.docker_mock"
  rm -f "$docker_log_file"

  run_dockistrate add-backend "$domain" nginx:alpine 18182 http >/dev/null
  assertEquals "seed backend" 0 $?
  run_dockistrate set-backend-acl-policy "$domain" allow >/dev/null
  assertEquals "seed backend ACL policy override" 0 $?

  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      DOCKER_MOCK_PS_NAMES='' \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate start-nginx 2>&1
  )"
  status=$?
  assertEquals "start managed nginx" 0 "$status"
  assertStringContains "start-nginx output" "Nginx proxy running." "$output"

  DOCKER_MOCK_LOG_FILE="$docker_log_file" \
    PATH="${MOCK_BIN_DIR}:$PATH" \
    docker stop nginx-proxy >/dev/null
  : >"$docker_log_file"

  output="$(
    DOCKER_MOCK_LOG_FILE="$docker_log_file" \
      SKIP_DOCKER_CHECKS=false \
      run_dockistrate remove-backend "$domain" 2>&1
  )"
  status=$?
  assertEquals "remove-backend should succeed with deferred security cleanup" 0 "$status"
  assertNotContains "remove-backend should not run readiness during deferred security cleanup" \
    "$output" "Nginx container is not running after security config update"
  assertTrue "remove-backend should remove backend state" \
    "! grep -Fq 'backend,${domain},' '${BACKEND_PORTS_FILE}'"
  assertTrue "final nginx update should consume deferred recreate request" \
    "grep -Fq 'subcommand=run -d --name nginx-proxy' '${docker_log_file}'"
}
