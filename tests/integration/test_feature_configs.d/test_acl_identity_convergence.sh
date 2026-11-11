#!/usr/bin/env bash

function _acl_identity_run() {
  # Keep current bindings equal to the fixture's configured listener. Otherwise
  # generic updates also recreate for a port mismatch, hiding missing security
  # replacement requests and defeating the ordinary-reload control cases.
  DOCKER_MOCK_PORT_BINDINGS='80/tcp -> 0.0.0.0:80' \
    DOCKER_MOCK_LOG_FILE="$acl_docker_log" SKIP_DOCKER_CHECKS=false run_dockistrate "$@"
}

function _acl_identity_seed() {
  acl_docker_log="$STATE_DIR/acl_identity_docker.log"
  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend identity.test nginx:alpine 18180 http >/dev/null || return 1
  run_dockistrate set-trusted-proxies 127.0.0.1/32 >/dev/null || return 1
  run_dockistrate set-backend-client-ip-header identity.test X-Client-IP >/dev/null || return 1
  DOCKER_MOCK_PS_NAMES='' _acl_identity_run start-nginx >/dev/null || return 1
  : >"$acl_docker_log"
}

function _acl_identity_assert_replaced() {
  local label="$1"
  assertTrue "$label should replace the old proxy before checking the new configuration" \
    "awk '/subcommand=rm -f -v nginx-proxy/ { removed=1 } /subcommand=run -d --name nginx-proxy/ { if (removed) replaced=1 } /subcommand=exec nginx-proxy nginx -t -c/ { if (replaced) ready=1 } END { exit !ready }' '$acl_docker_log'"
  assertFalse "$label must not rely on graceful reload" \
    "grep -Fq 'nginx -s reload' '$acl_docker_log'"
}

function _acl_identity_assert_reload() {
  local label="$1"
  assertTrue "$label should keep ordinary reload behavior" \
    "grep -Fq 'nginx -s reload' '$acl_docker_log'"
  assertFalse "$label should not replace the proxy" \
    "grep -Fq 'subcommand=run -d --name nginx-proxy' '$acl_docker_log'"
}

function test_acl_identity_global_changes_replace_proxy() {
  local acl_docker_log="" output status
  _acl_identity_seed || { fail 'seed ACL identity runtime'; return; }

  output="$(_acl_identity_run set-trusted-proxies none)"; status=$?
  assertEquals "trusted proxy revocation succeeds: $output" 0 "$status"
  _acl_identity_assert_replaced 'trusted proxy revocation'
  assertFalse 'revoked trust must disappear from generated config' \
    "grep -Fq 'set_real_ip_from 127.0.0.1/32;' '$CONFIG_DIR/nginx_conf/conf.d/backends.conf'"

  : >"$acl_docker_log"
  output="$(_acl_identity_run set-real-ip-recursive off)"; status=$?
  assertEquals "recursive identity update succeeds: $output" 0 "$status"
  _acl_identity_assert_replaced 'recursive identity update'
  assertFileContainsSubstring 'real_ip_recursive off;' "$CONFIG_DIR/nginx_conf/conf.d/backends.conf"

  : >"$acl_docker_log"
  output="$(_acl_identity_run set-client-ip-header off)"; status=$?
  assertEquals "global identity header update succeeds: $output" 0 "$status"
  _acl_identity_assert_replaced 'global identity header update'
  assertEquals "Global identity header is explicitly disabled" "" "$(integration_global_csv_get "$CONFIG_DIR/global_settings.csv" CLIENT_IP_HEADER)"
  assertFileContainsSubstring 'real_ip_header X-Client-IP;' "$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
}

function test_acl_identity_backend_override_and_removal_replace_proxy() {
  local acl_docker_log="" output status
  _acl_identity_seed || { fail 'seed ACL backend identity runtime'; return; }

  output="$(_acl_identity_run set-backend-client-ip-header identity.test off)"; status=$?
  assertEquals "backend header disable succeeds: $output" 0 "$status"
  _acl_identity_assert_replaced 'backend identity header disable'
  assertFalse 'disabled backend identity must not emit real_ip_header' \
    "grep -Fq 'real_ip_header ' '$CONFIG_DIR/nginx_conf/conf.d/backends.conf'"
  assertFileContainsSubstring 'identity.test,off' "$CONFIG_DIR/backend_client_ip_headers.csv"

  : >"$acl_docker_log"
  output="$(_acl_identity_run remove-backend-client-ip-header identity.test)"; status=$?
  assertEquals "backend override removal succeeds: $output" 0 "$status"
  _acl_identity_assert_replaced 'backend identity override removal'
  assertFileContainsSubstring 'real_ip_header X-Forwarded-For;' "$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
  assertFalse 'backend header row is removed' \
    "grep -Fq 'identity.test,' '$CONFIG_DIR/backend_client_ip_headers.csv'"
}

function test_acl_identity_inheritance_replaces_only_security_effective_settings() {
  local acl_docker_log="" setting output status
  _acl_identity_seed || { fail 'seed dedicated identity runtime'; return; }
  _acl_identity_run add-dedicated-host dedicated.identity.test identity.test >/dev/null || {
    fail 'seed dedicated host'; return;
  }

  for setting in acl security_rules headers all; do
    : >"$acl_docker_log"
    output="$(_acl_identity_run set-dedicated-host-inherit dedicated.identity.test "$setting" no)"; status=$?
    assertEquals "$setting inheritance update succeeds: $output" 0 "$status"
    _acl_identity_assert_replaced "$setting inheritance"
  done
  assertFileContainsSubstring 'dedicated.identity.test,no,no,no,no,no' "$CONFIG_DIR/dedicated_host_inheritance.csv"

  for setting in mtls paths; do
    : >"$acl_docker_log"
    output="$(_acl_identity_run set-dedicated-host-inherit dedicated.identity.test "$setting" yes)"; status=$?
    assertEquals "$setting inheritance update succeeds: $output" 0 "$status"
    _acl_identity_assert_reload "$setting inheritance"
  done
  assertFileContainsSubstring 'dedicated.identity.test,yes,no,no,no,yes' "$CONFIG_DIR/dedicated_host_inheritance.csv"

  : >"$acl_docker_log"
  output="$(_acl_identity_run set-proxy-ip-header X-Upstream-IP)"; status=$?
  assertEquals "outbound proxy header update succeeds: $output" 0 "$status"
  _acl_identity_assert_reload 'outbound proxy identity header'
}

function test_acl_identity_readiness_failure_restores_saved_and_rendered_state() {
  local acl_docker_log="" command output status before after readiness_failure_marker
  local original_proxy_image restored_proxy_image restored_proxy_state journal pending_journal
  _acl_identity_seed || { fail 'seed ACL rollback runtime'; return; }
  _acl_identity_run add-dedicated-host dedicated.identity.test identity.test >/dev/null || {
    fail 'seed rollback dedicated host'; return;
  }
  original_proxy_image="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
    bash "$MOCK_BIN_DIR/docker" inspect -f '{{.Config.Image}}' nginx-proxy)"

  for command in trust backend inheritance; do
    before="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
    : >"$acl_docker_log"
    readiness_failure_marker="$STATE_DIR/acl_readiness_${command}.failed"
    # Fail the new proxy once. A persistent exec fault also prevents rollback
    # readiness, leaving a journal that blocks the following operation.
    case "$command" in
    trust) output="$(DOCKER_MOCK_NGINX_TEST_FAIL_ONCE_FILE="$readiness_failure_marker" DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS=1 _acl_identity_run set-trusted-proxies none)"; status=$? ;;
    backend) output="$(DOCKER_MOCK_NGINX_TEST_FAIL_ONCE_FILE="$readiness_failure_marker" DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS=1 _acl_identity_run remove-backend-client-ip-header identity.test)"; status=$? ;;
    inheritance) output="$(DOCKER_MOCK_NGINX_TEST_FAIL_ONCE_FILE="$readiness_failure_marker" DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS=1 _acl_identity_run set-dedicated-host-inherit dedicated.identity.test headers no)"; status=$? ;;
    esac
    assertNotEquals "$command must fail when replacement is not ready" 0 "$status"
    assertTrue "$command should consume its own post-activation readiness failure" "[ -f '$readiness_failure_marker' ]"
    assertStringContains "$command readiness diagnostic" 'Nginx did not pass config readiness checks' "$output"
    assertStringContains "$command rollback must complete" 'failed. Rolled back.' "$output"
    after="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
    assertEquals "$command must restore settings and generated config together" "$before" "$after"
    assertTrue "$command should restore the old runtime after failed readiness" \
      "awk '/subcommand=exec nginx-proxy nginx -t -c/ { failed_ready=1 } /subcommand=run -d --name nginx-proxy/ { if (failed_ready) restored=1 } END { exit !restored }' '$acl_docker_log'"
    pending_journal=false
    for journal in "$STATE_DIR/runtime/transactions"/apply.* "$STATE_DIR/runtime/transactions"/preparing.*; do
      [ ! -d "$journal" ] || pending_journal=true
    done
    assertEquals "$command must leave no pending recovery journal" false "$pending_journal"
    restored_proxy_image="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
      bash "$MOCK_BIN_DIR/docker" inspect -f '{{.Config.Image}}' nginx-proxy)"
    restored_proxy_state="$(DOCKER_MOCK_RUNTIME_DIR="${STATE_DIR}/tmp/.docker_mock" \
      bash "$MOCK_BIN_DIR/docker" inspect -f '{{.State.Status}}' nginx-proxy)"
    assertEquals "$command should restore the original proxy image" "$original_proxy_image" "$restored_proxy_image"
    assertEquals "$command should restore a running proxy" running "$restored_proxy_state"
    output="$(_acl_identity_run check-config)"; status=$?
    assertEquals "$command restored proxy should pass check-config: $output" 0 "$status"
  done
}

function test_acl_identity_invalid_values_preserve_policy_and_runtime() {
  local acl_docker_log="" command output status before after
  _acl_identity_seed || { fail 'seed ACL invalid-input runtime'; return; }
  _acl_identity_run add-dedicated-host dedicated.identity.test identity.test >/dev/null || {
    fail 'seed invalid-input dedicated host'; return;
  }
  for command in trust recursive global_header backend_header inheritance; do
    before="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
    : >"$acl_docker_log"
    case "$command" in
    trust) output="$(_acl_identity_run set-trusted-proxies '127.0.0.1/32;')"; status=$? ;;
    recursive) output="$(_acl_identity_run set-real-ip-recursive invalid)"; status=$? ;;
    global_header) output="$(_acl_identity_run set-client-ip-header 'bad header')"; status=$? ;;
    backend_header) output="$(_acl_identity_run set-backend-client-ip-header identity.test 'bad header')"; status=$? ;;
    inheritance) output="$(_acl_identity_run set-dedicated-host-inherit dedicated.identity.test acl invalid)"; status=$? ;;
    esac
    assertNotEquals "$command invalid input must fail: $output" 0 "$status"
    after="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
    assertEquals "$command invalid input must preserve saved and generated config" "$before" "$after"
    assertFalse "$command invalid input must not replace or reload the proxy" \
      "grep -Eq 'subcommand=(run|rm)|nginx -s reload' '$acl_docker_log'"
  done
}
