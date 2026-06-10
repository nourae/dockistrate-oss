#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib/state_sandbox.sh
source "${ROOT_DIR}/tests/lib/state_sandbox.sh"
OUTSIDE_ROOT=""

function cleanup() {
  if [ -n "${OUTSIDE_ROOT:-}" ]; then
    rm -rf "$OUTSIDE_ROOT"
  fi
  dockistrate_test_state_sandbox_restore
}
trap cleanup EXIT

dockistrate_test_state_sandbox "$ROOT_DIR"
OUTSIDE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_removed_envs.XXXXXX")"

EXTERNAL_STATE_DIR="${OUTSIDE_ROOT}/external-state"
EXTERNAL_CONFIG_DIR="${OUTSIDE_ROOT}/external-config"
RUNTIME_STATE_DIR="${ROOT_DIR}/state"
REMOVED_ENV_PATTERN='(^|[^A-Za-z0-9_])(DOCKISTRATE_STATE_DIR|DOCKISTRATE_CONFIG_DIR|DOCKISTRATE_CAPTURE_IMAGE|DOCKISTRATE_TLS_KEYLOG_PERMISSIVE|DOCKISTRATE_NGINX_CONTAINER_NAME)([^A-Za-z0-9_]|$)'

if command -v rg >/dev/null 2>&1; then
  search_removed_env_refs() {
    rg -n "$REMOVED_ENV_PATTERN" \
      "$ROOT_DIR/lib" "$ROOT_DIR/dockistrate.sh"
  }
else
  search_removed_env_refs() {
    grep -R -n -E "$REMOVED_ENV_PATTERN" \
      "$ROOT_DIR/lib" "$ROOT_DIR/dockistrate.sh"
  }
fi

if search_removed_env_refs >/dev/null; then
  echo "[Error] Removed operator env overrides are still referenced by production code." >&2
  exit 1
fi

if output="$(
  cd "$ROOT_DIR" && \
    PATH="${ROOT_DIR}/tests/mocks:$PATH" \
    SKIP_DOCKER_CHECKS=true \
    DOCKISTRATE_STATE_DIR="$EXTERNAL_STATE_DIR" \
    DOCKISTRATE_CONFIG_DIR="$EXTERNAL_CONFIG_DIR" \
    DOCKER_MOCK_PS_NAMES="nginx-proxy" \
    DOCKER_MOCK_INSPECT_STATUS="running" \
    DOCKISTRATE_NGINX_CONTAINER_NAME="custom-proxy" \
    ./dockistrate.sh status 2>&1
)"; then
  status=0
else
  status=$?
fi

if [ "$status" -ne 0 ]; then
  printf 'Expected status command to ignore removed env overrides, got exit %s\n%s\n' "$status" "$output" >&2
  exit 1
fi

if [ ! -f "${RUNTIME_STATE_DIR}/config/global_settings.csv" ]; then
  echo "[Error] Dockistrate should still write runtime state under the repo-local state directory." >&2
  exit 1
fi

if [ -e "${EXTERNAL_STATE_DIR}" ] || [ -e "${EXTERNAL_CONFIG_DIR}" ]; then
  echo "[Error] Removed state/config env overrides should not create external runtime roots." >&2
  exit 1
fi

if ! grep -Fq "nginx-proxy status: running" <<<"$output"; then
  echo "[Error] Dockistrate should ignore removed proxy name env overrides and report the fixed nginx-proxy container." >&2
  exit 1
fi

if grep -Fq "custom-proxy" <<<"$output"; then
  echo "[Error] Removed proxy name env overrides should not influence status output." >&2
  exit 1
fi

echo "Removed operator env overrides are ignored and runtime stays under the repo-local state directory."
