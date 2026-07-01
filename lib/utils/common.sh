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

function push_skip_update_nginx_config() {
  local __out="${1:-}"
  if [[ ! "$__out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "[Error] Invalid output variable name: $__out" >&2
    return 1
  fi

  if [ "${SKIP_UPDATE_NGINX_CONFIG+x}" = "x" ]; then
    printf -v "$__out" '%s' "$SKIP_UPDATE_NGINX_CONFIG"
  else
    printf -v "$__out" '%s' "__dockistrate_unset__"
  fi
  SKIP_UPDATE_NGINX_CONFIG=true
}

function pop_skip_update_nginx_config() {
  local previous="${1:-__dockistrate_unset__}"
  if [ "$previous" = "__dockistrate_unset__" ]; then
    unset SKIP_UPDATE_NGINX_CONFIG
  else
    SKIP_UPDATE_NGINX_CONFIG="$previous"
  fi
}
