#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/backups/_config_checksum.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_checksum.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

echo "hello" >"${tmp_dir}/file.txt"

checksum="$(_config_checksum "$tmp_dir")"
if [[ ! "$checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "[Error] Expected SHA-256 checksum, got: ${checksum}" >&2
  exit 1
fi

echo "Config checksum SHA-256 check passed."
