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
source "$ROOT_DIR/lib/ports.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/certs.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SKIP_DOCKER_CHECKS=true

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
CERTS_DIR="$STATE_DIR/certs"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
NGINX_DIRECTIVES_GLOBAL_INCLUDE_FILE="$NGINX_HTTP_CONF_DIR/nginx_directives_global.inc"
NGINX_DIRECTIVES_STREAM_GLOBAL_INCLUDE_FILE="$NGINX_STREAM_CONF_DIR/nginx_directives_stream_global.inc"
SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha1"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_RULES_DB="$SECURITY_RULES_FILE"
SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha1"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR" \
  "$CERTS_DIR/letsencrypt/live" "$CERTS_DIR/letsencrypt/archive" "$CERTS_DIR/letsencrypt/renewal" \
  "$ACME_WEBROOT_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,443,8000,https,letsencrypt/live/example.com_443,no,off,,off,auto,,,,,,
port,example.com,,,,,8443,8000,https,letsencrypt/live/example.com_8443,no,off,,off,auto,,,,,,
EOF_PORTS

SOURCE_DIR="$CERTS_DIR/letsencrypt/live/example.com"
PORT_443_DIR="$CERTS_DIR/letsencrypt/live/example.com_443"
PORT_8443_DIR="$CERTS_DIR/letsencrypt/live/example.com_8443"
mkdir -p "$SOURCE_DIR" "$PORT_443_DIR" "$PORT_8443_DIR"

openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
  -keyout "$SOURCE_DIR/privkey.pem" \
  -out "$SOURCE_DIR/fullchain.pem" \
  -subj '/CN=example.com' >/dev/null 2>&1
cp "$SOURCE_DIR/fullchain.pem" "$PORT_443_DIR/fullchain.pem"
cp "$SOURCE_DIR/privkey.pem" "$PORT_443_DIR/privkey.pem"
cp "$SOURCE_DIR/fullchain.pem" "$PORT_8443_DIR/fullchain.pem"
cp "$SOURCE_DIR/privkey.pem" "$PORT_8443_DIR/privkey.pem"
chmod 640 "$SOURCE_DIR/fullchain.pem" "$SOURCE_DIR/privkey.pem" \
  "$PORT_443_DIR/fullchain.pem" "$PORT_443_DIR/privkey.pem" \
  "$PORT_8443_DIR/fullchain.pem" "$PORT_8443_DIR/privkey.pem"

RENEW_CALL_COUNT=0
RENEW_CALLS=""

function _cert_expiring_soon() { return 0; }
function _notify_cert_warning() { :; }
function update_nginx_config() { :; }
function _renew_letsencrypt_cert() {
  local source_domain="${1:-}"
  RENEW_CALL_COUNT=$((RENEW_CALL_COUNT + 1))
  RENEW_CALLS+="|${source_domain}|"
  printf 'renewed-fullchain-%s\n' "$source_domain" >"${CERTS_DIR}/letsencrypt/live/${source_domain}/fullchain.pem"
  printf 'renewed-privkey-%s\n' "$source_domain" >"${CERTS_DIR}/letsencrypt/live/${source_domain}/privkey.pem"
}

renew_certs >/dev/null

if [ "$RENEW_CALL_COUNT" -ne 1 ]; then
  echo "[Error] renew-certs renewed shared source ${RENEW_CALL_COUNT} times instead of once" >&2
  exit 1
fi

if [ "$RENEW_CALLS" != "|example.com|" ]; then
  echo "[Error] renew-certs renewed unexpected source domains: ${RENEW_CALLS}" >&2
  exit 1
fi

for cert_copy in "$PORT_443_DIR/fullchain.pem" "$PORT_8443_DIR/fullchain.pem"; do
  if ! grep -Fq 'renewed-fullchain-example.com' "$cert_copy"; then
    echo "[Error] renew-certs did not refresh consumer copy $cert_copy from the shared source" >&2
    exit 1
  fi
done

for key_copy in "$PORT_443_DIR/privkey.pem" "$PORT_8443_DIR/privkey.pem"; do
  if ! grep -Fq 'renewed-privkey-example.com' "$key_copy"; then
    echo "[Error] renew-certs did not refresh consumer key copy $key_copy from the shared source" >&2
    exit 1
  fi
done

printf 'Shared-source renew-certs dedupe regression checks passed.\n'
