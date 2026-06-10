#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/state"

CONFIG_DIR="${STATE_DIR}/config"
LOG_DIR="${STATE_DIR}/logs"
ERROR_LOG_DIR="${LOG_DIR}/errors"
TMP_DIR="${STATE_DIR}/tmp"
CAPTURE_DIR="${STATE_DIR}/pcaps"
BACKUP_DIR="${STATE_DIR}/backups"
ACME_WEBROOT_DIR="${STATE_DIR}/acme-webroot"
CERTS_DIR="${STATE_DIR}/certs"

GLOBAL_SETTINGS_FILE="${CONFIG_DIR}/global_settings.csv"
LOG_FILE="${LOG_DIR}/docker_manager.log"
AUDIT_LOG_FILE="${LOG_DIR}/audit.log"
BACKEND_DOCKER_OPTS_FILE="${CONFIG_DIR}/backend_docker_opts.csv"
CAPTURE_TLS_STATE_FILE="${CONFIG_DIR}/capture_tls_decrypt.state"
BACKUP_ARCHIVE_FILE="${BACKUP_DIR}/after-fix.tar.gz"
PCAP_FILE="${CAPTURE_DIR}/after-fix.pcap"

function get_mode() {
  local target="$1" mode=""
  if mode=$(stat -c '%a' "$target" 2>/dev/null); then
    printf '%s' "$mode"
    return 0
  fi
  stat -f '%Lp' "$target"
}

function assert_mode() {
  local target="$1" expected="$2" label="$3"
  local actual=""
  actual="$(get_mode "$target")"
  if [ "$actual" != "$expected" ]; then
    printf 'Expected %s mode %s but got %s (%s)\n' "$label" "$expected" "$actual" "$target" >&2
    exit 1
  fi
}

mkdir -p "$CONFIG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$CAPTURE_DIR" "$BACKUP_DIR" "$ACME_WEBROOT_DIR" "$CERTS_DIR"
touch "$GLOBAL_SETTINGS_FILE" "$LOG_FILE" "$AUDIT_LOG_FILE" "$BACKEND_DOCKER_OPTS_FILE" "$CAPTURE_TLS_STATE_FILE" "$BACKUP_ARCHIVE_FILE" "$PCAP_FILE"
chmod 777 "$STATE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$CAPTURE_DIR" "$BACKUP_DIR" "$ACME_WEBROOT_DIR" "$CERTS_DIR"
chmod 666 "$GLOBAL_SETTINGS_FILE" "$LOG_FILE" "$AUDIT_LOG_FILE" "$BACKEND_DOCKER_OPTS_FILE" "$CAPTURE_TLS_STATE_FILE" "$BACKUP_ARCHIVE_FILE" "$PCAP_FILE"

if output="$(
  cd "$ROOT_DIR" && \
    PATH="${ROOT_DIR}/tests/mocks:$PATH" SKIP_DOCKER_CHECKS=true ./dockistrate.sh fix-permissions "$STATE_DIR" 2>&1
)"; then
  status=0
else
  status=$?
fi
if [ "$status" -ne 0 ]; then
  printf 'Expected fix-permissions to succeed, got exit %s\n%s\n' "$status" "$output" >&2
  exit 1
fi

assert_mode "$STATE_DIR" 750 "state directory"
assert_mode "$CONFIG_DIR" 750 "config directory"
assert_mode "$LOG_DIR" 750 "logs directory"
assert_mode "$ERROR_LOG_DIR" 750 "error logs directory"
assert_mode "$TMP_DIR" 700 "tmp directory"
assert_mode "$CAPTURE_DIR" 700 "capture directory"
assert_mode "$BACKUP_DIR" 700 "backup directory"
assert_mode "$ACME_WEBROOT_DIR" 750 "acme webroot directory"
assert_mode "$CERTS_DIR" 750 "certs directory"

assert_mode "$GLOBAL_SETTINGS_FILE" 640 "global settings file"
assert_mode "$LOG_FILE" 640 "main log file"
assert_mode "$AUDIT_LOG_FILE" 640 "audit log file"
assert_mode "$BACKEND_DOCKER_OPTS_FILE" 600 "backend docker opts file"
assert_mode "$CAPTURE_TLS_STATE_FILE" 600 "capture tls state file"
assert_mode "$BACKUP_ARCHIVE_FILE" 600 "backup archive file"
assert_mode "$PCAP_FILE" 600 "pcap file"

echo "fix-permissions runtime state hardening checks passed."
