# shellcheck shell=bash

function check_docker_installed() {
  if ! command -v docker &>/dev/null; then
    # When running with sudo on macOS, /usr/local/bin may be missing from PATH
    if [ -x /usr/local/bin/docker ]; then
      export PATH="$PATH:/usr/local/bin"
    fi
  fi
  if ! command -v docker &>/dev/null; then
    echo "[Error] Docker is not installed." >&2
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "[Error] Please install Docker Desktop from https://docs.docker.com/docker-for-mac/install/" >&2
      exit 1
    fi
    if [ "$INTERACTIVE" = true ]; then
      read_with_editing "Install Docker now? (y/n): " ans
      if [[ $ans =~ ^[Yy] ]]; then
        install_package docker.io || install_package docker
        if ! command -v docker &>/dev/null; then
          echo "[Error] Docker install failed." >&2
          exit 1
        fi
        echo "[Info] Docker installed."
        log_msg "Docker installed by script."
      else
        echo "[Error] Docker required. Exiting." >&2
        exit 1
      fi
    else
      echo "[Error] Docker required. Exiting." >&2
      exit 1
    fi
  fi
}
