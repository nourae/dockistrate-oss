#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/utils.sh"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_atomic.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

target="${tmp_root}/target.txt"
tmp=""
make_temp_for_file tmp "$target"

if [ -z "$tmp" ]; then
  echo "[Error] make_temp_for_file did not set output variable." >&2
  exit 1
fi

if [ ! -f "$tmp" ]; then
  echo "[Error] Temporary file was not created: $tmp" >&2
  exit 1
fi

rm -f "$tmp"

echo "Atomic write output var check passed."
