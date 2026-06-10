#!/usr/bin/env bash

function run_dockistrate() {
  local cmd_output
  local skip_docker_checks="${SKIP_DOCKER_CHECKS:-true}"
  cmd_output=$(cd "$ROOT_DIR" && PATH="${MOCK_BIN_DIR}:$PATH" SKIP_DOCKER_CHECKS="$skip_docker_checks" ./dockistrate.sh "$@" 2>&1)
  local status=$?
  printf '%s' "$cmd_output"
  return $status
}
