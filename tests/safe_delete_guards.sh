#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_safe_delete.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

allowed_root="${TMP_ROOT}/allowed"
outside_root="${TMP_ROOT}/outside"
mkdir -p "$allowed_root/subdir" "$outside_root"
touch "$allowed_root/subdir/file.txt"
touch "$outside_root/outside.txt"
mkdir -p "$allowed_root/dir_to_remove"
touch "$allowed_root/dir_to_remove/value.txt"

safe_rm_f "$allowed_root/subdir/file.txt" "$allowed_root"
if [ -e "$allowed_root/subdir/file.txt" ]; then
  echo "[Error] safe_rm_f failed to remove allowed file." >&2
  exit 1
fi

safe_rm_rf "$allowed_root/dir_to_remove" "$allowed_root"
if [ -e "$allowed_root/dir_to_remove" ]; then
  echo "[Error] safe_rm_rf failed to remove allowed directory." >&2
  exit 1
fi

set +e
safe_rm_rf "" "$allowed_root" >/dev/null 2>&1
empty_status=$?
safe_rm_rf "/" "$allowed_root" >/dev/null 2>&1
root_status=$?
safe_rm_f "$outside_root/outside.txt" "$allowed_root" >/dev/null 2>&1
outside_status=$?
set -e

if [ "$empty_status" -eq 0 ]; then
  echo "[Error] safe_rm_rf should reject empty targets." >&2
  exit 1
fi

if [ "$root_status" -eq 0 ]; then
  echo "[Error] safe_rm_rf should reject root path deletions." >&2
  exit 1
fi

if [ "$outside_status" -eq 0 ]; then
  echo "[Error] safe_rm_f should reject paths outside allowed roots." >&2
  exit 1
fi

if [ ! -f "$outside_root/outside.txt" ]; then
  echo "[Error] Guarded delete removed a path outside the allowed root." >&2
  exit 1
fi

printf 'Safe delete guard checks passed.\n'
