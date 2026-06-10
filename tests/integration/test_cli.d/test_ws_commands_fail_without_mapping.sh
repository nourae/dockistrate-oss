#!/usr/bin/env bash

test_ws_commands_fail_without_mapping() {
  local output status

  output="$(run_dockistrate enable-ws missing.example 80)"
  status=$?
  assertTrue "enable-ws without mapping should fail" "[ $status -ne 0 ]"
  assertStringContains "enable-ws error message" \
    "Port mapping for missing.example on port 80 not found." "$output"

  output="$(run_dockistrate disable-ws missing.example 80)"
  status=$?
  assertTrue "disable-ws without mapping should fail" "[ $status -ne 0 ]"
  assertStringContains "disable-ws error message" \
    "Port mapping for missing.example on port 80 not found." "$output"
}
