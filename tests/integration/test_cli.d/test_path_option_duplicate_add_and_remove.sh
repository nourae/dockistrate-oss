#!/usr/bin/env bash

test_path_option_duplicate_add_and_remove() {
  run_dockistrate add-backend pathopts.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  run_dockistrate add-port pathopts.test 18180 18180 http none no >/dev/null
  assertEquals "seed port mapping" 0 $?

  local output
  output="$(run_dockistrate add-path-option pathopts.test 18180 /api --ws yes --redirect off --headers none 2>&1)"
  assertEquals "first add-path-option should succeed" 0 $?
  assertStringContains "add-path-option output" "Added path override pathopts.test:18180 /api." "$output"

  output="$(run_dockistrate add-path-option pathopts.test 18180 /api --ws yes --redirect off --headers none 2>&1)"
  assertNotEquals "duplicate add-path-option should fail" 0 $?
  assertStringContains "duplicate add-path-option error" "already exists" "$output"

  output="$(run_dockistrate remove-path-option pathopts.test 18180 /api 2>&1)"
  assertEquals "remove-path-option should succeed for existing row" 0 $?
  assertStringContains "remove-path-option output" "Removed path override pathopts.test:18180/api." "$output"

  if grep -Fq "path,pathopts.test,,,/api,,18180,,,,yes,off," "${CONFIG_DIR}/backend_ports.csv"; then
    fail "Expected /api path row to be removed from backend_ports.csv"
  fi

  output="$(run_dockistrate remove-path-option pathopts.test 18180 /api 2>&1)"
  assertNotEquals "second remove-path-option should fail" 0 $?
  assertStringContains "missing row remove error" "not found" "$output"
}
