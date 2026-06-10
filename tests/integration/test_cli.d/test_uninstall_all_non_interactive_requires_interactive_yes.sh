#!/usr/bin/env bash

test_uninstall_all_non_interactive_requires_interactive_yes_and_rejects_force_flag() {
  run_dockistrate add-backend wipe.me nginx:alpine 5050 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  assertTrue "backend_ports.csv should exist after seeding" "[ -f '${CONFIG_DIR}/backend_ports.csv' ]"

  local fail_output
  fail_output="$(run_dockistrate uninstall-all)"
  local status=$?
  assertTrue "uninstall-all should fail without interactive YES" "[ $status -ne 0 ]"
  assertStringContains "non-interactive error should mention interactive rerun" \
    "Re-run with -i/--interactive and type YES to proceed." "$fail_output"
  assertStringContains "abort output should still be emitted" "[Info] Aborting." "$fail_output"
  assertTrue "backend_ports.csv should remain after refusal" "[ -f '${CONFIG_DIR}/backend_ports.csv' ]"

  fail_output="$(run_dockistrate uninstall-all --force)"
  status=$?
  assertTrue "uninstall-all with removed --force should fail" "[ $status -ne 0 ]"
  assertStringContains "removed force flag error" "Unknown argument '--force'" "$fail_output"
}
