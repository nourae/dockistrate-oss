#!/usr/bin/env bash

test_invoking_without_command_exits_nonzero() {
  local output status
  output="$(run_dockistrate)"
  status=$?

  assertTrue "running dockistrate without a command should fail" "[ $status -ne 0 ]"
  assertStringContains "usage output should be shown" "Usage:" "$output"
}
