#!/usr/bin/env bash

test_control_server_tokens_uses_directive_engine_state() {
  local output directives_file
  directives_file="${CONFIG_DIR}/nginx_directives.csv"

  output="$(run_dockistrate control-server-tokens on)"
  assertEquals "control-server-tokens on" 0 $?

  assertTrue "directive state file should exist" "[ -f '$directives_file' ]"
  assertStringContains "directive row should contain managed server_tokens on" \
    "global,,,,managed,server_tokens,on" \
    "$(cat "$directives_file")"
  assertTrue "legacy server_tokens.conf should not be written" "[ ! -f '${CONFIG_DIR}/nginx_conf/conf.d/server_tokens.conf' ]"

  output="$(run_dockistrate show-server-tokens)"
  assertEquals "show-server-tokens after on" "on" "$output"

  output="$(run_dockistrate control-server-tokens off)"
  assertEquals "control-server-tokens off" 0 $?

  local row_count
  row_count="$(awk -F',' 'NR>1 && $1=="global" && $5=="managed" && $6=="server_tokens" {c++} END {print c+0}' "$directives_file")"
  assertEquals "managed server_tokens row should upsert" 1 "$row_count"
  assertStringContains "directive row should contain managed server_tokens off" \
    "global,,,,managed,server_tokens,off" \
    "$(cat "$directives_file")"

  local global_include="${CONFIG_DIR}/nginx_conf/conf.d/nginx_directives_global.inc"
  assertStringContains "global include should render server_tokens off" \
    "server_tokens off;" \
    "$(cat "$global_include")"
}

test_nginx_directives_cleanup_hooks() {
  local directives_file
  directives_file="${CONFIG_DIR}/nginx_directives.csv"

  run_dockistrate add-backend cleanup-port.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for remove-port cleanup" 0 $?
  run_dockistrate set-nginx-directive port cleanup-port.test 80 proxy_read_timeout 30s >/dev/null
  assertEquals "seed port scoped directive" 0 $?
  run_dockistrate remove-port cleanup-port.test 80 >/dev/null
  assertEquals "remove-port" 0 $?
  if grep -q '^port,cleanup-port.test,80,' "$directives_file"; then
    fail "Expected remove-port to clear matching directive rows"
  fi

  run_dockistrate add-backend cleanup-port-dh.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for dedicated remove-port cleanup" 0 $?
  run_dockistrate add-dedicated-host admin.cleanup-port-dh.test cleanup-port-dh.test >/dev/null
  assertEquals "add dedicated host for remove-port cleanup" 0 $?
  run_dockistrate set-nginx-directive port admin.cleanup-port-dh.test 80 proxy_read_timeout 31s >/dev/null
  assertEquals "seed dedicated host port directive" 0 $?
  run_dockistrate remove-port cleanup-port-dh.test 80 >/dev/null
  assertEquals "remove-port with dedicated host" 0 $?
  if grep -q '^port,admin.cleanup-port-dh.test,80,' "$directives_file"; then
    fail "Expected remove-port to clear matching dedicated host port directive rows"
  fi

  run_dockistrate add-backend cleanup-backend.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for remove-backend cleanup" 0 $?
  run_dockistrate set-nginx-directive backend cleanup-backend.test send_timeout 20s >/dev/null
  assertEquals "seed backend directive" 0 $?
  run_dockistrate remove-backend cleanup-backend.test >/dev/null
  assertEquals "remove-backend" 0 $?
  if grep -q ',cleanup-backend.test,' "$directives_file"; then
    fail "Expected remove-backend to clear directive rows for domain"
  fi

  run_dockistrate add-backend cleanup-backend-dh.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for dedicated remove-backend cleanup" 0 $?
  run_dockistrate add-dedicated-host admin.cleanup-backend-dh.test cleanup-backend-dh.test >/dev/null
  assertEquals "add dedicated host for remove-backend cleanup" 0 $?
  run_dockistrate set-nginx-directive backend admin.cleanup-backend-dh.test send_timeout 24s >/dev/null
  assertEquals "seed dedicated host backend directive" 0 $?
  run_dockistrate set-nginx-directive port admin.cleanup-backend-dh.test 80 proxy_read_timeout 24s >/dev/null
  assertEquals "seed dedicated host port directive for remove-backend cleanup" 0 $?
  run_dockistrate remove-backend cleanup-backend-dh.test >/dev/null
  assertEquals "remove-backend with dedicated host" 0 $?
  if grep -q ',admin.cleanup-backend-dh.test,' "$directives_file"; then
    fail "Expected remove-backend to clear directive rows for dedicated hosts of domain"
  fi

  run_dockistrate add-backend cleanup-dh.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for dedicated cleanup" 0 $?
  run_dockistrate add-dedicated-host admin.cleanup-dh.test cleanup-dh.test >/dev/null
  assertEquals "add dedicated host" 0 $?
  run_dockistrate set-nginx-directive backend admin.cleanup-dh.test send_timeout 21s >/dev/null
  assertEquals "seed dedicated host directive" 0 $?
  run_dockistrate remove-dedicated-host admin.cleanup-dh.test >/dev/null
  assertEquals "remove dedicated host" 0 $?
  if grep -q ',admin.cleanup-dh.test,' "$directives_file"; then
    fail "Expected remove-dedicated-host to clear directive rows for dedicated host"
  fi

  run_dockistrate add-backend cleanup-all.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for clean-all cleanup" 0 $?
  run_dockistrate set-nginx-directive backend cleanup-all.test send_timeout 22s >/dev/null
  assertEquals "seed clean-all directive" 0 $?
  run_dockistrate clean-all cleanup-all.test >/dev/null
  assertEquals "clean-all" 0 $?
  if grep -q ',cleanup-all.test,' "$directives_file"; then
    fail "Expected clean-all to clear directive rows for domain"
  fi

  run_dockistrate add-backend cleanup-all-dh.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for dedicated clean-all cleanup" 0 $?
  run_dockistrate add-dedicated-host admin.cleanup-all-dh.test cleanup-all-dh.test >/dev/null
  assertEquals "add dedicated host for clean-all cleanup" 0 $?
  run_dockistrate set-nginx-directive backend admin.cleanup-all-dh.test send_timeout 26s >/dev/null
  assertEquals "seed dedicated host directive for clean-all cleanup" 0 $?
  run_dockistrate clean-all cleanup-all-dh.test >/dev/null
  assertEquals "clean-all with dedicated host" 0 $?
  if grep -q ',admin.cleanup-all-dh.test,' "$directives_file"; then
    fail "Expected clean-all to clear directive rows for dedicated hosts of domain"
  fi

  run_dockistrate add-backend cleanup-uninstall.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend for uninstall cleanup" 0 $?
  run_dockistrate set-nginx-directive backend cleanup-uninstall.test send_timeout 23s >/dev/null
  assertEquals "seed uninstall directive" 0 $?
  run_dockistrate_with_interactive_yes uninstall-all --scope backend >/dev/null
  assertEquals "uninstall-all backend" 0 $?
  assertTrue "backend-scope uninstall should remove directive state file" "[ ! -f '$directives_file' ]"
}

test_status_shows_nginx_directive_section() {
  local output

  output="$(run_dockistrate status)"
  assertEquals "status baseline" 0 $?
  assertStringContains "status includes directive section" "=== Nginx Directive Overrides ===" "$output"

  run_dockistrate set-nginx-directive global client_max_body_size 12m >/dev/null
  assertEquals "seed directive for status" 0 $?

  output="$(run_dockistrate status)"
  assertEquals "status after directive" 0 $?
  assertStringContains "status includes strict mode" "Strict Mode:" "$output"
  assertStringContains "status includes directive key" "client_max_body_size" "$output"
}
