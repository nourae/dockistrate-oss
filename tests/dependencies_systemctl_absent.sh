#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/logging.sh
source "$ROOT_DIR/lib/logging.sh"
# shellcheck source=../lib/dependencies.sh
source "$ROOT_DIR/lib/dependencies.sh"

# The systemd branch of ensure_docker_running doesn't run on macOS, so skip this
# regression on Darwin to keep the suite portable.
if [[ "$(uname)" == "Darwin" ]]; then
  echo "[Skip] dependencies_systemctl_absent is Linux/systemd-specific; skipping on macOS."
  exit 0
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/docker" <<'EOF'
cmd="$1"
shift || true

case "$cmd" in
  info)
    counter_file="${DOCKER_MOCK_INFO_COUNTER_FILE:-}"
    fail_count="${DOCKER_MOCK_INFO_FAIL_COUNT:-0}"
    count=0
    if [ -n "$counter_file" ]; then
      if [ -f "$counter_file" ]; then
        count="$(cat "$counter_file")"
      fi
      count=$((count+1))
      echo "$count" >"$counter_file"
    else
      count=1
    fi
    if [ "$count" -le "$fail_count" ]; then
      echo "docker daemon unavailable" >&2
      exit 1
    fi
    exit 0
    ;;
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$tmp_dir/docker"

export DOCKER_MOCK_INFO_COUNTER_FILE="$tmp_dir/docker-info-count"
export DOCKER_MOCK_INFO_FAIL_COUNT=1

# Prefer the docker stub while keeping the host PATH intact.
export PATH="$tmp_dir:$PATH"

MOCK_NO_SYSTEMD=true

INTERACTIVE=false

set +e
output="$(ensure_docker_running 2>&1)"
status=$?
set -e

if [ $status -ne 0 ]; then
  printf 'Expected ensure_docker_running to succeed but exited with %s. Output:%s\n' "$status" "\n$output" >&2
  exit 1
fi

if [[ "$output" != *"systemctl not found"* ]]; then
  printf 'Expected warning about missing systemctl. Output:%s\n' "\n$output" >&2
  exit 1
fi

if [[ "$output" != *"Docker started."* ]]; then
  printf 'Expected success confirmation. Output:%s\n' "\n$output" >&2
  exit 1
fi

unset MOCK_NO_SYSTEMD

printf 'Dependencies check handles missing systemctl.\n'
