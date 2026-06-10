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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_backend_decline.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"

INTERACTIVE=true

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$CERTS_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,80,8000,http,none,no,off,,off,auto,,,,,,
EOF_PORTS

cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"

BEGIN_TXN_CALLED="false"
UPDATE_NGINX_CALLED="false"
REMOVE_CONTAINER_CALLED="false"

function confirm_prompt() { return 1; }
function container_exists() { [ "${1:-}" = "backend-example.com" ]; }
function begin_transaction() { BEGIN_TXN_CALLED="true"; return 0; }
function update_nginx_config() { UPDATE_NGINX_CALLED="true"; return 0; }
function remove_container_and_anonymous_volumes() { REMOVE_CONTAINER_CALLED="true"; return 0; }
function log_msg() { :; }

output="$(remove_backend example.com 2>&1)"
status=$?

if [ "$status" -ne 0 ]; then
  echo "[Error] remove_backend should exit successfully when the operator declines container removal." >&2
  exit 1
fi

if ! grep -Fq "[Info] Aborting." <<<"$output"; then
  echo "[Error] Expected remove_backend to report that it aborted after the declined confirmation." >&2
  exit 1
fi

if [ "$BEGIN_TXN_CALLED" != "false" ]; then
  echo "[Error] remove_backend should not start a transaction when the container-removal confirmation is declined." >&2
  exit 1
fi

if [ "$UPDATE_NGINX_CALLED" != "false" ]; then
  echo "[Error] remove_backend should not update nginx when the container-removal confirmation is declined." >&2
  exit 1
fi

if [ "$REMOVE_CONTAINER_CALLED" != "false" ]; then
  echo "[Error] remove_backend should not remove the backend container when the confirmation is declined." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"; then
  echo "[Error] remove_backend mutated backend_ports.csv even though the operator declined container removal." >&2
  exit 1
fi

printf 'remove_backend aborts cleanly when container deletion is declined.\n'
