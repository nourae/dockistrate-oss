#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.logging-entrypoints.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

LOG_FILE_PATH="${TMP_DIR}/test.log"
LOG_FILE="$LOG_FILE_PATH" ENABLE_LOGGING=true VERBOSE=false ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/logging/log_msg.sh
  source "$ROOT_DIR/lib/logging/log_msg.sh"
  if ! declare -F ensure_log_writable >/dev/null 2>&1; then
    echo "ensure_log_writable should be available after directly sourcing log_msg.sh" >&2
    exit 1
  fi
  log_msg hello
'

if [ ! -f "$LOG_FILE_PATH" ]; then
  echo "Expected direct sourcing log_msg.sh to create the log file." >&2
  exit 1
fi

if ! grep -q "hello" "$LOG_FILE_PATH"; then
  echo "Expected log_msg output to include the message." >&2
  exit 1
fi

AUDIT_LOG_FILE_PATH="${TMP_DIR}/audit.log"
AUDIT_LOG_FILE="$AUDIT_LOG_FILE_PATH" ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/logging/audit_log.sh
  source "$ROOT_DIR/lib/logging/audit_log.sh"
  if ! declare -F ensure_log_writable >/dev/null 2>&1; then
    echo "ensure_log_writable should be available after directly sourcing audit_log.sh" >&2
    exit 1
  fi
  audit_log hello
'

if [ ! -f "$AUDIT_LOG_FILE_PATH" ]; then
  echo "Expected direct sourcing audit_log.sh to create the audit log file." >&2
  exit 1
fi

if ! grep -q "hello" "$AUDIT_LOG_FILE_PATH"; then
  echo "Expected audit_log output to include the message." >&2
  exit 1
fi

echo "Logging entrypoint direct sourcing checks passed."
