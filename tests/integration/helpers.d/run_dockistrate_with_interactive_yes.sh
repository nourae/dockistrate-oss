#!/usr/bin/env bash

function run_dockistrate_with_interactive_yes() {
  local cmd_output
  local skip_docker_checks="${SKIP_DOCKER_CHECKS:-true}"
  local runtime_path="${INTEGRATION_RUNTIME_PATH:-${MOCK_BIN_DIR}:$PATH}"

  cmd_output="$(
    cd "$ROOT_DIR" &&
      printf '%s\n' "YES" | env PATH="$runtime_path" SKIP_DOCKER_CHECKS="$skip_docker_checks" ./dockistrate.sh -i "$@" 2>&1
  )"
  local status=$?
  printf '%s' "$cmd_output"
  return $status
}
