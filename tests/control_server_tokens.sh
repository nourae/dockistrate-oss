#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/state"
CONFIG_DIR="${STATE_DIR}/config"
BACKUP_DIR="${STATE_DIR}/backups"

CONF_D_DIR="${CONFIG_DIR}/nginx_conf/conf.d"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
RESTORE_DIR="${TMP_DIR}/conf.d.original"

TOKENS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control_server_tokens.d"
if [ -d "$TOKENS_DIR" ]; then
  for token_file in "$TOKENS_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$token_file"
  done
fi

cleanup() {
  if [ -d "$RESTORE_DIR" ]; then
    mv "$RESTORE_DIR" "$CONF_D_DIR"
  fi

  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

if [ -d "$CONF_D_DIR" ]; then
  mv "$CONF_D_DIR" "$RESTORE_DIR"
fi

trap cleanup EXIT

test_control_server_tokens_creates_conf_dir_when_missing
