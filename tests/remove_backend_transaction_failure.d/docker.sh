#!/usr/bin/env bash

function docker() {
  if [ "${1:-}" = "rm" ]; then
    printf '%s\n' "${@: -1}" >"$docker_rm_failure_marker"
    return 1
  fi
  DOCKER_MOCK_RUNTIME_DIR="$TMP_ROOT/docker" "$ROOT_DIR/tests/mocks/docker" "$@"
}
