# shellcheck shell=bash

function ensure_docker_running() {
  if docker info >/dev/null 2>&1; then
    return
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    echo "[Info] Attempting to start Docker Desktop..."
    open -a Docker >/dev/null 2>&1 || true
    local tries=0
    until docker info >/dev/null 2>&1 || [ $tries -ge 15 ]; do
      sleep 2
      tries=$((tries + 1))
    done
    if ! docker info >/dev/null 2>&1; then
      echo "[Error] Failed to start Docker. Please start Docker Desktop manually." >&2
      exit 1
    fi
    echo "[Info] Docker started."
    return
  fi

  echo "[Info] Docker installed but not running. Starting..."
  local tries=0
  local has_systemctl=true
  if [ "${MOCK_NO_SYSTEMD:-false}" = true ]; then
    has_systemctl=false
  elif ! command -v systemctl >/dev/null 2>&1; then
    has_systemctl=false
  fi

  if [ "$has_systemctl" = true ]; then
    ensure_root
    systemctl start docker >/dev/null 2>&1 || true
  else
    echo "[Warn] systemctl not found; unable to manage the Docker service automatically."
    if [ "${INTERACTIVE:-false}" = true ]; then
      read_with_editing "Please start Docker manually and press Enter to continue..." _
    else
      echo "[Warn] Waiting for Docker to be started manually..."
    fi
  fi

  until docker info >/dev/null 2>&1 || [ $tries -ge 15 ]; do
    sleep 2
    tries=$((tries + 1))
  done

  if ! docker info >/dev/null 2>&1; then
    echo "[Error] Failed to start Docker." >&2
    exit 1
  fi

  echo "[Info] Docker started."
}

# Verify the current user can run Docker commands
