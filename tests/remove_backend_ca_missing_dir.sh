#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_remove.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

STATE_DIR="$TMP_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
CERTS_DIR="$STATE_DIR/certs"
BACKUP_DIR="$STATE_DIR/backups"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$CERTS_DIR/mtls" "$BACKUP_DIR"

function update_nginx_config() { :; }
function begin_transaction() { ROLLBACK_DESC="test"; }
function end_transaction_success() { :; }

cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_MTLS

remove_backend_ca example.com

if grep -q '^example.com,' "$BACKEND_MTLS_FILE"; then
  echo "[Error] Expected mTLS entry removed even when directory missing." >&2
  exit 1
fi

if [ -e "${CERTS_DIR}/mtls/example.com" ] || [ -L "${CERTS_DIR}/mtls/example.com" ]; then
  echo "[Error] Expected mTLS directory to remain missing." >&2
  exit 1
fi

echo "remove-backend-ca missing directory check passed."
