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
source "$ROOT_DIR/lib/clean_uninstall.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_uninstall_guard.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

INTERACTIVE=true

function read_with_editing() {
  local prompt="${1:-}" __out="${2:-}"
  printf -v "$__out" '%s' "YES"
  return 0
}

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$CAPTURE_DIR" "$ACME_WEBROOT_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" \
  "$PATH_HEADER_DIR" "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS
touch "$NGINX_CONFIG_DIR/backends.conf"

OUTSIDE_ROOT="$TMP_ROOT/outside_certs"
mkdir -p "$OUTSIDE_ROOT"
touch "$OUTSIDE_ROOT/cert.pem"
CERTS_DIR="$OUTSIDE_ROOT"

cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"

set +e
output="$(uninstall_all 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] uninstall_all succeeded unexpectedly with CERTS_DIR outside state root." >&2
  exit 1
fi

if ! grep -Fq "outside allowed roots" <<<"$output"; then
  echo "[Error] Expected safe-delete guard error for outside CERTS_DIR." >&2
  exit 1
fi

if [ ! -f "$OUTSIDE_ROOT/cert.pem" ]; then
  echo "[Error] Guard failure path removed outside cert material." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"; then
  echo "[Error] Rollback did not restore backend state after guard failure." >&2
  exit 1
fi

printf 'Uninstall-all safe-delete guard checks passed.\n'
