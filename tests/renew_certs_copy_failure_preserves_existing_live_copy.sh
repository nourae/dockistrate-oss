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

# shellcheck disable=SC2218
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,443,8000,https,letsencrypt/live/example.com_443,no,off,,off,auto,,,,,,
EOF_PORTS

SOURCE_DIR="$CERTS_DIR/letsencrypt/live/example.com"
PORT_443_DIR="$CERTS_DIR/letsencrypt/live/example.com_443"
mkdir -p "$SOURCE_DIR" "$PORT_443_DIR"

printf 'old-source-fullchain\n' >"$SOURCE_DIR/fullchain.pem"
printf 'old-source-privkey\n' >"$SOURCE_DIR/privkey.pem"
printf 'old-copy-fullchain\n' >"$PORT_443_DIR/fullchain.pem"
printf 'old-copy-privkey\n' >"$PORT_443_DIR/privkey.pem"
chmod 640 "$SOURCE_DIR/fullchain.pem" "$PORT_443_DIR/fullchain.pem"
chmod 600 "$SOURCE_DIR/privkey.pem" "$PORT_443_DIR/privkey.pem"

function _cert_expiring_soon() { return 0; }
function _notify_cert_warning() { :; }
function update_nginx_config() { :; }
function _renew_letsencrypt_cert() {
  local source_domain="${1:-}"
  printf 'renewed-fullchain-%s\n' "$source_domain" >"${CERTS_DIR}/letsencrypt/live/${source_domain}/fullchain.pem"
  printf 'renewed-privkey-%s\n' "$source_domain" >"${CERTS_DIR}/letsencrypt/live/${source_domain}/privkey.pem"
}
function cat() {
  if [ "${1:-}" = "$SOURCE_DIR/privkey.pem" ]; then
    return 1
  fi
  command cat "$@"
}

set +e
output="$(renew_certs 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] renew_certs succeeded unexpectedly during live-copy refresh failure." >&2
  exit 1
fi

if [ "$(command cat "$PORT_443_DIR/fullchain.pem")" != "old-copy-fullchain" ]; then
  echo "[Error] Existing fullchain copy was modified after atomic refresh failure." >&2
  exit 1
fi

if [ "$(command cat "$PORT_443_DIR/privkey.pem")" != "old-copy-privkey" ]; then
  echo "[Error] Existing privkey copy was modified after atomic refresh failure." >&2
  exit 1
fi

if [ "$(command cat "$SOURCE_DIR/fullchain.pem")" != "old-source-fullchain" ]; then
  echo "[Error] Source fullchain should have been restored by rollback after refresh failure." >&2
  exit 1
fi

if [ "$(command cat "$SOURCE_DIR/privkey.pem")" != "old-source-privkey" ]; then
  echo "[Error] Source privkey should have been restored by rollback after refresh failure." >&2
  exit 1
fi

if find "$PORT_443_DIR" -maxdepth 1 -name '.fullchain.pem.tmp.*' -o -name '.privkey.pem.tmp.*' | grep -q .; then
  echo "[Error] Temporary cert files were left behind in the live copy directory." >&2
  exit 1
fi

if [[ "$output" != *'Failed to copy '* ]] || [[ "$output" != *'Rolled back.'* ]]; then
  echo "[Error] Expected atomic live-copy refresh failure output missing." >&2
  echo "$output" >&2
  exit 1
fi

echo "renew_certs live-copy refresh failure preserves existing files."
