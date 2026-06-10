#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/logging/ensure_log_writable.sh
source "${ROOT_DIR}/lib/logging/ensure_log_writable.sh"

if ! declare -F _effective_user >/dev/null 2>&1; then
  echo "Expected direct sourcing ensure_log_writable.sh to load _effective_user." >&2
  exit 1
fi

# shellcheck source=../lib/logging/audit_log.sh
source "${ROOT_DIR}/lib/logging/audit_log.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.auditnorm.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

AUDIT_LOG_FILE="${TMP_DIR}/audit.log"

audit_log $'user=alice\tactor\nattempt\rid=\00142'

if [ ! -f "$AUDIT_LOG_FILE" ]; then
  echo "Expected audit log to be created." >&2
  exit 1
fi

line_count="$(wc -l <"$AUDIT_LOG_FILE" 2>/dev/null || echo 0)"
line_count="${line_count//[[:space:]]/}"
if [ "$line_count" != "1" ]; then
  printf 'Expected a single normalized audit line, got %s lines.\n' "$line_count" >&2
  exit 1
fi

audit_entry="$(cat "$AUDIT_LOG_FILE")"
message="${audit_entry#*] }"
expected_message="user=alice actor attempt id= 42"
if [ "$message" != "$expected_message" ]; then
  printf 'Expected normalized audit message "%s" but got "%s"\n' "$expected_message" "$message" >&2
  exit 1
fi

echo "Audit log normalization checks passed."
