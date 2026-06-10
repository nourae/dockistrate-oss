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

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_replace_ca_fail.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls/example.com"

cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_MTLS

mtls_dir="${CERTS_DIR}/mtls/example.com"
printf 'old-ca\n' >"${mtls_dir}/ca.crt"
printf 'old-key\n' >"${mtls_dir}/ca.key"
printf 'old-client\n' >"${mtls_dir}/client1.crt"
printf 'old-client-key\n' >"${mtls_dir}/client1.key"
printf 'old-crl\n' >"${mtls_dir}/ca.crl"
printf 'old-marker\n' >"${mtls_dir}/marker.txt"
mkdir -p "${mtls_dir}/newcerts"

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() { return 1; }
function _ensure_tls_permissions() { :; }
function openssl() {
  local cmd="${1:-}" keyout="" out=""
  shift || true
  case "$cmd" in
    req)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -keyout)
            shift
            keyout="${1:-}"
            ;;
          -out)
            shift
            out="${1:-}"
            ;;
        esac
        shift || true
      done
      [ -n "$keyout" ] && printf 'new-key\n' >"$keyout"
      [ -n "$out" ] && printf 'new-ca\n' >"$out"
      return 0
      ;;
    ca)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -out)
            shift
            out="${1:-}"
            ;;
        esac
        shift || true
      done
      [ -n "$out" ] && printf 'new-crl\n' >"$out"
      return 0
      ;;
  esac
  command openssl "$cmd" "$@"
}

set +e
set +E
output="$(
  (replace_backend_ca example.com) 2>&1
)"
status=$?
set -E
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] replace_backend_ca succeeded unexpectedly." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/ca.crt")" != "old-ca" ]; then
  echo "[Error] CA certificate was not restored after rollback." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/client1.crt")" != "old-client" ]; then
  echo "[Error] Client certificate was not restored after rollback." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/ca.crl")" != "old-crl" ]; then
  echo "[Error] CRL was not restored after rollback." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/marker.txt")" != "old-marker" ]; then
  echo "[Error] Extra mTLS artifacts were not restored after rollback." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_MTLS_FILE" <(cat <<EOF_EXPECTED
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_EXPECTED
); then
  echo "[Error] mTLS state mapping changed after rollback." >&2
  exit 1
fi

if ! grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Expected rollback message missing for replace_backend_ca failure." >&2
  echo "$output" >&2
  exit 1
fi

if grep -Fq "Replaced CA for example.com" <<<"$output"; then
  echo "[Error] replace_backend_ca reported success after helper failure." >&2
  echo "$output" >&2
  exit 1
fi

echo "replace-backend-ca rollback restores prior CA state."
