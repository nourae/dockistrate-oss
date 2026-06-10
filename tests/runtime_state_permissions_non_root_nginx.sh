#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/permissions/common.sh
source "$ROOT_DIR/lib/permissions/common.sh"

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.nonrootperm.XXXXXX")"
trap 'rm -rf "$STATE_DIR"' EXIT

CONFIG_DIR="${STATE_DIR}/config"
LOG_DIR="${STATE_DIR}/logs"
ERROR_LOG_DIR="${LOG_DIR}/errors"
TMP_DIR="${STATE_DIR}/tmp"
CAPTURE_DIR="${STATE_DIR}/pcaps"
BACKUP_DIR="${STATE_DIR}/backups"
ACME_WEBROOT_DIR="${STATE_DIR}/acme-webroot"
CERTS_DIR="${STATE_DIR}/certs"

NGINX_CONFIG_DIR="${CONFIG_DIR}/nginx_conf"
NGINX_HTTP_CONF_DIR="${NGINX_CONFIG_DIR}/conf.d"
NGINX_STREAM_CONF_DIR="${NGINX_CONFIG_DIR}/stream_conf"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$CAPTURE_DIR" "$BACKUP_DIR" "$ACME_WEBROOT_DIR" "$CERTS_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
chmod 777 "$CONFIG_DIR" "$NGINX_CONFIG_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"

function _nginx_image_runs_as_root() {
  return 1
}

function mode_of() {
  local target="$1"
  if stat -c '%a' "$target" >/dev/null 2>&1; then
    stat -c '%a' "$target"
  else
    stat -f '%Lp' "$target"
  fi
}

function assert_mode() {
  local target="$1" expected="$2"
  local actual
  actual="$(mode_of "$target")"
  if [ "$actual" != "$expected" ]; then
    echo "Expected $target mode $expected, got $actual" >&2
    exit 1
  fi
}

ensure_runtime_state_permissions

assert_mode "$CONFIG_DIR" 750
assert_mode "$NGINX_CONFIG_DIR" 755
assert_mode "$NGINX_HTTP_CONF_DIR" 755
assert_mode "$NGINX_STREAM_CONF_DIR" 755

echo "non-root nginx runtime state permission checks passed."
