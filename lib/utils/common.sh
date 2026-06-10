# shellcheck shell=bash
DEFAULT_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_STATE_DIR="${DEFAULT_BASE_DIR}/state"
: "${CONFIG_DIR:="${DEFAULT_STATE_DIR}/config"}"

function require_option_value() {
  local option="${1:-option}"
  shift || true

  if [ "$#" -lt 1 ]; then
    echo "[Error] ${option} requires a value." >&2
    return 1
  fi

  return 0
}
