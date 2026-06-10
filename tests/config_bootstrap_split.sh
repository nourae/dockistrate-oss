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
source "$ROOT_DIR/lib/access_log.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_config_bootstrap.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

STATE_DIR="$TMP_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
cat >"$GLOBAL_SETTINGS_FILE" <<'EOF_CONFIG'
setting_key,setting_value
ENABLE_AUTO_BACKUPS,true
BACKUP_RETENTION,0
ENABLE_BACKUP_COMPRESSION,true
HTTP_VERSION,http2
CLIENT_IP_HEADER,X-Forwarded-For
PROXY_IP_HEADER,X-Real-IP
TLS_PROTOCOLS,TLSv1.2 TLSv1.3
TLS_CIPHERS,HIGH:!aNULL:!MD5
SECURITY_RULE_STATUS,403
ACL_STATUS,403
ACL_POLICY,deny
TRUSTED_PROXY_RANGES,
REAL_IP_RECURSIVE,on
NGINX_IMAGE,nginx
CERTBOT_IMAGE,certbot/certbot
EOF_CONFIG
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.before"

load_config || fail_test "load_config should accept legacy settings file"
cmp -s "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.before" || fail_test "load_config should not rewrite global_settings.csv"
[ ! -e "$BACKEND_PORTS_FILE" ] || fail_test "load_config should not create backend_ports.csv"
[ ! -e "$ACCESS_LOG_FIELDS_FILE" ] || fail_test "load_config should not create access_log_fields.csv"

bootstrap_config_runtime || fail_test "bootstrap_config_runtime should repair runtime state"

grep -qx 'NGINX_DIRECTIVE_STRICT,on' "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime did not restore NGINX_DIRECTIVE_STRICT"
grep -qx 'NGINX_DOCKER_OPTS,' "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime did not restore NGINX_DOCKER_OPTS"
grep -qx 'NGINX_IMAGE,nginx:latest' "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime did not normalize NGINX_IMAGE"
grep -qx 'CERTBOT_IMAGE,certbot/certbot:latest' "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime did not normalize CERTBOT_IMAGE"
grep -qx 'NGINX_PULL_MODE,if-missing' "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime did not restore NGINX_PULL_MODE"
grep -qx 'CERTBOT_PULL_MODE,if-missing' "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime did not restore CERTBOT_PULL_MODE"
grep -qx 'TLS_CIPHERS,HIGH:!aNULL:!MD5' "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime should preserve explicit TLS_CIPHERS"

[ -f "$BACKEND_PORTS_FILE" ] || fail_test "bootstrap_config_runtime did not create backend_ports.csv"
[ -f "$ACCESS_LOG_FIELDS_FILE" ] || fail_test "bootstrap_config_runtime did not create access_log_fields.csv"
[ "$(awk 'END { print NR }' "$ACCESS_LOG_FIELDS_FILE")" -gt 1 ] || fail_test "bootstrap_config_runtime did not seed access_log_fields.csv"
[ ! -e "$LAST_POST_BACKUP_FILE" ] || fail_test "bootstrap_config_runtime should not record a post-change backup during runtime prep"
[ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)" ] || fail_test "bootstrap_config_runtime should not create backup archives during runtime prep"

seeded_post_backup="${BACKUP_DIR}/20260312_000001_post_runtime_prep_seed.tar.gz"
printf '%s\n' "$seeded_post_backup" >"$LAST_POST_BACKUP_FILE"

bootstrap_config_runtime || fail_test "bootstrap_config_runtime should remain clean on an already-prepared runtime state"
grep -qx "$seeded_post_backup" "$LAST_POST_BACKUP_FILE" || fail_test "bootstrap_config_runtime should preserve the existing post-change backup marker"
[ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)" ] || fail_test "bootstrap_config_runtime should not create backup archives on no-op runtime prep"

rm -rf "$STATE_DIR"
bootstrap_config_runtime || fail_test "bootstrap_config_runtime should seed fresh runtime state"
grep -qx "TLS_CIPHERS,${DEFAULT_TLS_CIPHERS}" "$GLOBAL_SETTINGS_FILE" || fail_test "bootstrap_config_runtime did not seed strict default TLS_CIPHERS"

echo "config bootstrap split checks passed."
