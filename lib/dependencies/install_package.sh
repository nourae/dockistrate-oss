# shellcheck shell=bash

function install_package() {
  local pkg="${1:-}"
  if [[ "$(uname)" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      echo "[Info] Installing ${pkg} via brew..."
      brew list "$pkg" &>/dev/null || brew install "$pkg"
    else
      echo "[Error] Homebrew not found. Please install ${pkg} manually." >&2
      exit 1
    fi
  else
    ensure_root
    if [ -f /etc/debian_version ]; then
      echo "[Info] Installing ${pkg} via apt-get..."
      apt-get update && apt-get install -y "$pkg"
    elif [ -f /etc/redhat-release ]; then
      echo "[Info] Installing ${pkg} via yum..."
      yum install -y "$pkg"
    else
      echo "[Error] Automatic installation for ${pkg} not supported. Install manually." >&2
      exit 1
    fi
  fi
}
