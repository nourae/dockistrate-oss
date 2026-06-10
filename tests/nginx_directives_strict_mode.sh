#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/state"

run_cmd() {
  (cd "$ROOT_DIR" && SKIP_DOCKER_CHECKS=true ./dockistrate.sh "$@")
}

strict_val="$(run_cmd show-nginx-directive-strict 2>/dev/null || true)"
if [ "$strict_val" != "on" ]; then
  echo "[Error] Expected strict mode default to be 'on', got '$strict_val'." >&2
  exit 1
fi

if run_cmd set-nginx-directive global server_tokens on >/dev/null 2>&1; then
  echo "[Error] Expected strict mode to reject owned directive writes from generic command." >&2
  exit 1
fi

if ! run_cmd set-nginx-directive-strict off >/dev/null 2>&1; then
  echo "[Error] Expected strict mode toggle off to succeed." >&2
  exit 1
fi

if ! run_cmd set-nginx-directive-raw global server_tokens on >/dev/null 2>&1; then
  echo "[Error] Expected raw owned directive write to succeed when strict mode is off." >&2
  exit 1
fi

if run_cmd set-nginx-directive-strict on >/dev/null 2>&1; then
  echo "[Error] Expected strict mode toggle on to fail when unmanaged owned rows exist." >&2
  exit 1
fi

strict_val="$(run_cmd show-nginx-directive-strict 2>/dev/null || true)"
if [ "$strict_val" != "off" ]; then
  echo "[Error] Expected strict mode toggle-on failure to rollback to 'off', got '$strict_val'." >&2
  exit 1
fi

if ! run_cmd remove-nginx-directive global server_tokens >/dev/null 2>&1; then
  echo "[Error] Expected removing unmanaged owned row to work while strict is off." >&2
  exit 1
fi

if ! run_cmd set-nginx-directive-strict on >/dev/null 2>&1; then
  echo "[Error] Expected strict mode to enable successfully after cleanup." >&2
  exit 1
fi

echo "[tests] nginx_directives_strict_mode.sh: PASS"
