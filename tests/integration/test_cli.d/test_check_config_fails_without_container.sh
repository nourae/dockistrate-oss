#!/usr/bin/env bash

test_check_config_fails_without_container() {
  local output status
  output="$(run_dockistrate check-config)"
  status=$?
  assertTrue "check-config should fail without container" "[ $status -ne 0 ]"
  assertStringContains "missing container message" "Nginx container not found" "$output"
}
