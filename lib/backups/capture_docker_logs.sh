# shellcheck shell=bash

# Capture docker logs for containers into ERROR_LOG_DIR
function capture_docker_logs() {
  local prefix="${1:-log}"
  shift
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$ERROR_LOG_DIR" "error log directory" || return 1
  fi
  mkdir -p "$ERROR_LOG_DIR"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$ERROR_LOG_DIR" "error log directory" || return 1
  fi
  local ts="$(date '+%Y%m%d_%H%M%S')"
  for c in "$@"; do
    local log_file="${ERROR_LOG_DIR}/${prefix}_${c}_${ts}.log"
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$log_file" "captured docker log file" || return 1
    fi
    docker logs "$c" &>"$log_file" || true
  done
}
