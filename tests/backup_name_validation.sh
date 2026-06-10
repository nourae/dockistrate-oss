#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/backups/common.sh"

fail=0

assert_true() {
  local label="$1"
  shift
  if ! "$@"; then
    echo "[Error] Expected true: $label" >&2
    fail=1
  fi
}

assert_false() {
  local label="$1"
  shift
  if "$@"; then
    echo "[Error] Expected false: $label" >&2
    fail=1
  fi
}

assert_true "accepts tar.gz name" is_valid_backup_name "20250101_010101_Auto.tar.gz"
assert_true "accepts folder name" is_valid_backup_name "20250101_010101_Auto"
assert_false "rejects slash" is_valid_backup_name "2025/01"
assert_false "rejects backslash" is_valid_backup_name "2025\\01"
assert_false "rejects dotdot" is_valid_backup_name "2025..01"

sanitized="$(_sanitize_backup_label "bad/../name")"
if [[ "$sanitized" == *"/"* || "$sanitized" == *".."* || "$sanitized" == *"\\"* ]]; then
  echo "[Error] _sanitize_backup_label did not remove unsafe patterns: $sanitized" >&2
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "Backup name validation checks passed."
fi

exit "$fail"
