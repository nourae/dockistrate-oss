#!/usr/bin/env bash

test_nginx_directives_dedicated_host_fallback_precedence() {
  local output
  output="$(run_dockistrate add-backend fallback.test nginx:alpine 18180 http)"
  assertEquals "add-backend" 0 $?

  output="$(run_dockistrate add-dedicated-host admin.fallback.test fallback.test)"
  assertEquals "add-dedicated-host" 0 $?

  output="$(run_dockistrate set-nginx-directive backend fallback.test send_timeout 25s)"
  assertEquals "set backend fallback directive" 0 $?

  local backends_conf="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
  local count_25
  count_25="$(grep -c 'send_timeout 25s;' "$backends_conf" || true)"
  assertEquals "backend fallback should apply to both base and dedicated host blocks" 2 "$count_25"

  output="$(run_dockistrate set-nginx-directive backend admin.fallback.test send_timeout 40s)"
  assertEquals "set dedicated host override directive" 0 $?

  count_25="$(grep -c 'send_timeout 25s;' "$backends_conf" || true)"
  local count_40
  count_40="$(grep -c 'send_timeout 40s;' "$backends_conf" || true)"
  assertEquals "base backend should keep fallback value" 1 "$count_25"
  assertEquals "dedicated host should override fallback value" 1 "$count_40"

  output="$(run_dockistrate add-backend fallback-port.test nginx:alpine 18180 http)"
  assertEquals "add-backend fallback-port" 0 $?

  output="$(run_dockistrate add-dedicated-host admin.fallback-port.test fallback-port.test)"
  assertEquals "add-dedicated-host fallback-port" 0 $?

  output="$(run_dockistrate set-nginx-directive port fallback-port.test 80 send_timeout 33s)"
  assertEquals "set backend port fallback directive" 0 $?

  local count_33
  count_33="$(grep -c 'send_timeout 33s;' "$backends_conf" || true)"
  assertEquals "backend port fallback should apply to both base and dedicated host blocks" 2 "$count_33"

  output="$(run_dockistrate set-nginx-directive port admin.fallback-port.test 80 send_timeout 55s)"
  assertEquals "set dedicated host port override directive" 0 $?

  count_33="$(grep -c 'send_timeout 33s;' "$backends_conf" || true)"
  local count_55
  count_55="$(grep -c 'send_timeout 55s;' "$backends_conf" || true)"
  assertEquals "base backend should keep backend port fallback value" 1 "$count_33"
  assertEquals "dedicated host should override backend port fallback value" 1 "$count_55"

  output="$(run_dockistrate add-backend fallback-path.test nginx:alpine 18180 http)"
  assertEquals "add-backend fallback-path" 0 $?

  output="$(run_dockistrate add-path-option fallback-path.test 80 /api)"
  assertEquals "add-path-option /api" 0 $?

  output="$(run_dockistrate add-dedicated-host admin.fallback-path.test fallback-path.test)"
  assertEquals "add-dedicated-host fallback-path" 0 $?

  output="$(run_dockistrate set-nginx-directive path fallback-path.test 80 /api proxy_read_timeout 77s)"
  assertEquals "set backend path fallback directive" 0 $?

  local count_path_fallback
  count_path_fallback="$(grep -c 'proxy_read_timeout 77s;' "$backends_conf" || true)"
  assertEquals "backend path fallback should apply to base and dedicated host inherited path locations" 2 "$count_path_fallback"
}

test_nginx_directives_dedicated_host_path_inherit_enforcement_cleanup_safe() {
  local output

  output="$(run_dockistrate add-backend inherit-path-policy.test nginx:alpine 18180 http)"
  assertEquals "add-backend inherit-path-policy" 0 $?

  output="$(run_dockistrate add-path-option inherit-path-policy.test 80 /api)"
  assertEquals "add-path-option inherit-path-policy /api" 0 $?

  output="$(run_dockistrate add-dedicated-host admin.inherit-path-policy.test inherit-path-policy.test)"
  assertEquals "add-dedicated-host inherit-path-policy" 0 $?

  output="$(run_dockistrate set-nginx-directive path admin.inherit-path-policy.test 80 /api proxy_read_timeout 41s)"
  assertEquals "seed dedicated host path directive while inherit_paths=yes" 0 $?

  output="$(run_dockistrate set-dedicated-host-inherit admin.inherit-path-policy.test paths no)"
  assertEquals "disable inherit paths on dedicated host" 0 $?

  output="$(run_dockistrate set-nginx-directive path admin.inherit-path-policy.test 80 /api proxy_read_timeout 42s 2>&1)"
  assertNotEquals "set-nginx-directive path should fail when inherit_paths=no" 0 $?
  assertStringContains "set-nginx-directive path error should explain inherit_paths policy" "inherit_paths=no" "$output"

  output="$(run_dockistrate set-nginx-directive-raw path admin.inherit-path-policy.test 80 /api proxy_read_timeout 42s 2>&1)"
  assertNotEquals "set-nginx-directive-raw path should fail when inherit_paths=no" 0 $?
  assertStringContains "set-nginx-directive-raw path error should explain inherit_paths policy" "inherit_paths=no" "$output"

  output="$(run_dockistrate list-nginx-directives path admin.inherit-path-policy.test 80 /api)"
  assertEquals "list-nginx-directives path should remain usable for cleanup" 0 $?
  assertTrue "seeded directive name should remain listable for cleanup" \
    "printf '%s' \"$output\" | grep -Fq 'proxy_read_timeout'"
  assertTrue "seeded directive value should remain listable for cleanup" \
    "printf '%s' \"$output\" | grep -Fq '41s'"

  output="$(run_dockistrate remove-nginx-directive path admin.inherit-path-policy.test 80 /api proxy_read_timeout)"
  assertEquals "remove-nginx-directive path should remain usable for cleanup" 0 $?

  output="$(run_dockistrate list-nginx-directives path admin.inherit-path-policy.test 80 /api)"
  assertEquals "list-nginx-directives after cleanup remove" 0 $?
  if printf '%s' "$output" | grep -Fq 'proxy_read_timeout'; then
    fail "Expected path directive row to be removed during cleanup-safe flow"
  fi
}
