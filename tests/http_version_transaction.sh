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
source "$ROOT_DIR/lib/http_version.sh"

HTTP_VERSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/http_version_transaction.d"
if [ -d "$HTTP_VERSION_DIR" ]; then
  for stub_file in "$HTTP_VERSION_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$stub_file"
  done
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_http_version.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CAPTURE_DIR="$STATE_DIR/pcaps"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha1"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" \
  "$BACKUP_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"

ENABLE_AUTO_BACKUPS="true"
BACKUP_RETENTION="0"
ENABLE_BACKUP_COMPRESSION="true"
HTTP_VERSION="http1.1"
CLIENT_IP_HEADER="X-Forwarded-For"
PROXY_IP_HEADER="X-Real-IP"
TLS_PROTOCOLS="TLSv1.2 TLSv1.3"
TLS_CIPHERS="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
SECURITY_RULE_STATUS="403"
ACL_STATUS="403"
ACL_POLICY="deny"
TRUSTED_PROXY_RANGES=""
REAL_IP_RECURSIVE="on"

save_config

initial_version=$(awk -F',' '$1=="HTTP_VERSION" {print $2}' "$GLOBAL_SETTINGS_FILE")
if [ "$initial_version" != "http1.1" ]; then
  echo "[Error] Initial HTTP version not recorded" >&2
  exit 1
fi

set +e
(set_http_version http2)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] set_http_version succeeded unexpectedly" >&2
  exit 1
fi

post_version=$(awk -F',' '$1=="HTTP_VERSION" {print $2}' "$GLOBAL_SETTINGS_FILE")
if [ "$post_version" != "http1.1" ]; then
  echo "[Error] HTTP version was not restored after failure" >&2
  exit 1
fi

rollback_seed_backup="$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*pre_set_http_version*.tar.gz' -o -name '*post_save_config*.tar.gz' \) | head -n 1)"
if [ -z "$rollback_seed_backup" ]; then
  echo "[Error] Rollback seed archive for HTTP version change not created" >&2
  exit 1
fi

exit 0
