# shellcheck shell=bash

function check_dependencies() {
  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    # Minimal setup for commands that don't need Docker
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$BACKUP_DIR" "backup directory" || return 1
    fi
    mkdir -p "$BACKUP_DIR"
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$BACKUP_DIR" "backup directory" || return 1
    fi
    return
  fi
  check_docker_installed
  ensure_docker_running
  check_docker_access
  check_openssl_installed
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$BACKUP_DIR" "backup directory" || return 1
  fi
  mkdir -p "$BACKUP_DIR"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$BACKUP_DIR" "backup directory" || return 1
  fi
}
