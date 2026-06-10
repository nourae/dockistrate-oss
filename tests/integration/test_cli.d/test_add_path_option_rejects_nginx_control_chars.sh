#!/usr/bin/env bash

test_add_path_option_rejects_nginx_control_chars() {
  run_dockistrate add-backend path-injection.test nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?

  run_dockistrate add-port path-injection.test 18180 18180 http none no >/dev/null
  assertEquals "seed port mapping" 0 $?

  local output
  output="$(run_dockistrate add-path-option path-injection.test 18180 /api#oops --ws yes --redirect off --headers none 2>&1)"
  assertNotEquals "add-path-option should reject unsafe path prefixes" 0 $?
  assertStringContains "error should report invalid path" "Invalid path: /api#oops" "$output"

  assertTrue "unsafe path row must not be persisted" \
    "! grep -Fq 'path,path-injection.test,,,/api#oops' '${CONFIG_DIR}/backend_ports.csv'"
}
