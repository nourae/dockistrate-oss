#!/usr/bin/env bash

test_version_command_matches_version_file() {
  local expected version_flag_output version_cmd_output
  expected="$(<"${ROOT_DIR}/VERSION")"

  version_flag_output="$(run_dockistrate --version)"
  assertEquals "--version should succeed" 0 $?
  assertStringContains "--version output includes version" "$expected" "$version_flag_output"

  version_cmd_output="$(run_dockistrate version)"
  assertEquals "version subcommand should succeed" 0 $?
  assertStringContains "version command output includes version" "$expected" "$version_cmd_output"
}
