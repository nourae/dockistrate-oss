#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/dependencies/check_dependencies.sh
source "$ROOT_DIR/lib/dependencies/check_dependencies.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_deps_sslkeylog.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

BACKUP_DIR="$tmp_dir/backups"
sslkeylog_build_calls=0

function check_docker_installed() { :; }
function ensure_docker_running() { :; }
function check_docker_access() { :; }
function check_openssl_installed() { :; }
function ensure_sslkeylog_library() {
  sslkeylog_build_calls=$((sslkeylog_build_calls + 1))
  echo "[Error] ensure_sslkeylog_library should not run from check_dependencies." >&2
  return 1
}

SKIP_DOCKER_CHECKS=false
check_dependencies

if [ "$sslkeylog_build_calls" -ne 0 ]; then
  echo "[Error] check_dependencies should not build the TLS keylog helper for routine commands." >&2
  exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
  echo "[Error] check_dependencies should still create the backup directory." >&2
  exit 1
fi

echo "dependency checks do not build TLS keylog helper by default."
