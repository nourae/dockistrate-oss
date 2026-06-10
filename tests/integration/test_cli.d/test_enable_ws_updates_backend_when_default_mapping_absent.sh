#!/usr/bin/env bash

test_enable_ws_requires_port_mapping() {
  local output

  output="$(run_dockistrate add-backend ws-default.test nginx:alpine 8123 http --no-expose)"
  assertEquals "add-backend without exposure should succeed" 0 $?

  output="$(run_dockistrate enable-ws ws-default.test 80)"
  assertTrue "enable-ws without port mapping should fail" "[ $? -ne 0 ]"
  assertStringContains "enable-ws error message" \
    "Port mapping for ws-default.test on port 80 not found." "$output"
}
