#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate-error-stderr.XXXXXX")"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

if command -v rg >/dev/null 2>&1; then
  rg -n --no-ignore --no-heading '^[[:space:]]*echo .*\[Error\]' dockistrate.sh lib tests | \
    awk 'index($0, ">&2")==0 && index($0, "1>&2")==0 {print}' >"$tmp_file" || true
else
  grep -R -n -E '^[[:space:]]*echo .*\[Error\]' dockistrate.sh lib tests | \
    awk 'index($0, ">&2")==0 && index($0, "1>&2")==0 {print}' >"$tmp_file" || true
fi

if [ -s "$tmp_file" ]; then
  echo "[Error] Found [Error] echoes that are not routed to stderr." >&2
  sed 's/^/  - /' "$tmp_file" >&2
  exit 1
fi

echo "[tests] error_output_stderr_style.sh: PASS"
