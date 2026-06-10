#!/usr/bin/env bash

function integration_seed_managed_proxy() {
  local output="" status=0
  output="$(DOCKER_MOCK_INSPECT_STATUS=running SKIP_DOCKER_CHECKS=false run_dockistrate start-nginx 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return "$status"
  fi
  return 0
}
