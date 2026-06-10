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
source "$ROOT_DIR/lib/nginx.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/tls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_backend_mtls_guard.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SKIP_DOCKER_CHECKS=true
INTERACTIVE=false

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$CERTS_DIR" "$CERTS_DIR/mtls" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,18180,8000,http,,no,off,,off,auto,,,,,,
EOF_PORTS

OUTSIDE_MTLS_DIR="$TMP_ROOT/outside-mtls"
mkdir -p "$OUTSIDE_MTLS_DIR"
cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,$OUTSIDE_MTLS_DIR
EOF_MTLS

cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
cp "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"

set +e
output="$(remove_backend example.com 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] remove_backend succeeded unexpectedly for invalid mTLS path." >&2
  exit 1
fi

if ! grep -Fq "Refusing to remove mTLS material" <<<"$output"; then
  echo "[Error] Expected mTLS path guard error." >&2
  echo "$output" >&2
  exit 1
fi

if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"; then
  echo "[Error] Backend state changed despite guarded mTLS path failure." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"; then
  echo "[Error] mTLS state changed despite guarded mTLS path failure." >&2
  exit 1
fi

if [ ! -d "$OUTSIDE_MTLS_DIR" ]; then
  echo "[Error] Guarded failure removed outside mTLS directory." >&2
  exit 1
fi

printf 'Remove-backend mTLS path atomicity checks passed.\n'
