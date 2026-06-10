# shellcheck shell=bash

function check_docker_access() {
  if ! docker ps >/dev/null 2>&1; then
    echo "[Error] Unable to execute Docker commands. Ensure your user is in the docker group or run with sudo." >&2
    exit 1
  fi
}
