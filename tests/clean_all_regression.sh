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
source "$ROOT_DIR/lib/clean_uninstall.sh"
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

HTTP_VERSION="http2"
CLIENT_IP_HEADER="X-Forwarded-For"
PROXY_IP_HEADER="X-Real-IP"
TLS_PROTOCOLS="TLSv1.2 TLSv1.3"
TLS_CIPHERS="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
ACL_STATUS="403"
ACL_POLICY="deny"
SECURITY_RULE_STATUS="403"
TRUSTED_PROXY_RANGES=""
REAL_IP_RECURSIVE="on"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR" \
  "$CERTS_DIR" "$CERTS_DIR/mtls"

cat >"$GLOBAL_SETTINGS_FILE" <<EOF_SETTINGS
ENABLE_AUTO_BACKUPS,false
BACKUP_RETENTION,0
ENABLE_BACKUP_COMPRESSION,false
HTTP_VERSION,$HTTP_VERSION
CLIENT_IP_HEADER,$CLIENT_IP_HEADER
PROXY_IP_HEADER,$PROXY_IP_HEADER
TLS_PROTOCOLS,$TLS_PROTOCOLS
TLS_CIPHERS,$TLS_CIPHERS
SECURITY_RULE_STATUS,$SECURITY_RULE_STATUS
ACL_STATUS,$ACL_STATUS
ACL_POLICY,$ACL_POLICY
TRUSTED_PROXY_RANGES,$TRUSTED_PROXY_RANGES
REAL_IP_RECURSIVE,$REAL_IP_RECURSIVE
EOF_SETTINGS

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
backend,other.com,10.0.0.6:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,18180,8000,http,none,yes,off,,off,auto,,,,,,
path,example.com,,,/app,customset,18180,,,,inherit,off,,,,prefix,100,,none,-,auto
path,example.com,,,/shared,sharedset,18180,,,,inherit,off,,,,prefix,100,,none,-,auto
path,other.com,,,/shared,sharedset,18180,,,,inherit,off,,,,prefix,100,,none,-,auto
EOF_PORTS

cat >"$BACKEND_HEADERS_FILE" <<'EOF_BACKEND_HEADERS'
domain,header_type,header_name,header_value
example.com,response,X-Test,one
example.com,request,X-Req,two
other.com,response,X-Other,three
EOF_BACKEND_HEADERS

cat >"$BACKEND_HTTP_FILE" <<'EOF_BACKEND_HTTP'
domain,http_version
example.com,http2
admin.other.com,http1.1
other.com,http1.1
EOF_BACKEND_HTTP

MTLS_DIR="$CERTS_DIR/mtls/example.com"
mkdir -p "$MTLS_DIR"
touch "$MTLS_DIR/ca.crt" "$MTLS_DIR/ca.crl"
cat >"$BACKEND_MTLS_FILE" <<EOF_BACKEND_MTLS
domain,mtls_directory
example.com,$MTLS_DIR
other.com,$CERTS_DIR/mtls/other.com
EOF_BACKEND_MTLS

cat >"$BACKEND_CLIENT_IP_HEADER_FILE" <<'EOF_CLIENT'
domain,client_ip_header_name
example.com,X-Forwarded-For
other.com,X-Real-IP
EOF_CLIENT

cat >"$BACKEND_PROXY_IP_HEADER_FILE" <<'EOF_PROXY'
domain,proxy_ip_header_name
example.com,X-Original-IP
other.com,X-Forwarded-For
EOF_PROXY

cat >"$BACKEND_ACL_POLICY_FILE" <<'EOF_ACL'
domain,acl_policy
example.com,allow
other.com,deny
EOF_ACL

cat >"$BACKEND_ACL_STATUS_FILE" <<'EOF_ACL_STATUS'
domain,acl_status_code
example.com,401
other.com,403
EOF_ACL_STATUS

cat >"$BACKEND_SECURITY_RULE_STATUS_FILE" <<'EOF_SEC_STATUS'
domain,security_rule_status_code
example.com,429
other.com,403
EOF_SEC_STATUS

cat >"$SECURITY_IP_RULES_DB" <<'EOF_SEC_IP'
enabled,domain,scope,action,ip_value,status_code
1,Example.COM,l7,allow,10.0.0.0/24,200
0,Example.COM,l7,deny,198.51.100.5,403
1,other.com,l7,allow,192.168.1.0/24,200
EOF_SEC_IP

printf '%s\n' "enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location" >"$SECURITY_RULES_DB"
_sr_write_db_line 1 "Example.COM" "single" "429" "1" "header" "X-Test" "contains" "bad" >>"$SECURITY_RULES_DB"
_sr_write_db_line 1 "other.com" "single" "429" "1" "query" "q" "contains" "safe" >>"$SECURITY_RULES_DB"

cat >"$BACKEND_ALIASES_FILE" <<'EOF_ALIASES'
record_type,hostname,target_domain
dedicated,admin.example.com,example.com
dedicated,admin.other.com,other.com
EOF_ALIASES
set_dedicated_host_inheritance admin.other.com no no no no no

cat >"$PATH_HEADER_DIR/customset.conf" <<'EOF_CUSTOM'
# custom header directives
add_header X-Custom one;
EOF_CUSTOM

echo '# shared header directives' >"$PATH_HEADER_DIR/sharedset.conf"

clean_all example.com

if grep -q 'example.com' "$BACKEND_PORTS_FILE"; then
  echo "[Error] Domain entries still present in BACKEND_PORTS_FILE" >&2
  exit 1
fi

if grep -q 'example.com' "$BACKEND_HEADERS_FILE" 2>/dev/null; then
  echo "[Error] Domain headers not removed" >&2
  exit 1
fi

if grep -Eq '^example\.com,' "$BACKEND_HTTP_FILE" 2>/dev/null; then
  echo "[Error] HTTP override not removed" >&2
  exit 1
fi

if ! grep -Fxq 'admin.other.com,http1.1' "$BACKEND_HTTP_FILE" 2>/dev/null; then
  echo "[Error] Dedicated host override for surviving mapping was removed" >&2
  exit 1
fi

if ! grep -Fxq 'dedicated,admin.other.com,other.com' "$BACKEND_ALIASES_FILE" 2>/dev/null; then
  echo "[Error] Surviving dedicated host mapping was removed" >&2
  exit 1
fi

if ! grep -Fq 'admin.other.com' "$(dedicated_host_inheritance_file)" 2>/dev/null; then
  echo "[Error] Dedicated host inheritance for surviving mapping was removed" >&2
  exit 1
fi

if grep -q 'example.com' "$BACKEND_MTLS_FILE" 2>/dev/null; then
  echo "[Error] mTLS entry not removed" >&2
  exit 1
fi

if [ -d "$MTLS_DIR" ]; then
  echo "[Error] mTLS directory still present" >&2
  exit 1
fi

if grep -q 'example.com' "$BACKEND_CLIENT_IP_HEADER_FILE" 2>/dev/null; then
  echo "[Error] Client IP header override not removed" >&2
  exit 1
fi

if grep -q 'example.com' "$BACKEND_PROXY_IP_HEADER_FILE" 2>/dev/null; then
  echo "[Error] Proxy IP header override not removed" >&2
  exit 1
fi

if grep -q 'example.com' "$BACKEND_ACL_POLICY_FILE" 2>/dev/null; then
  echo "[Error] ACL policy override not removed" >&2
  exit 1
fi

if grep -q 'example.com' "$BACKEND_ACL_STATUS_FILE" 2>/dev/null; then
  echo "[Error] ACL status override not removed" >&2
  exit 1
fi

if grep -q 'example.com' "$BACKEND_SECURITY_RULE_STATUS_FILE" 2>/dev/null; then
  echo "[Error] Security rule status override not removed" >&2
  exit 1
fi

if grep -Fiq 'example.com' "$SECURITY_IP_RULES_DB" 2>/dev/null; then
  echo "[Error] Security IP rules not removed" >&2
  exit 1
fi

if grep -Fiq 'example.com' "$SECURITY_RULES_DB" 2>/dev/null; then
  echo "[Error] Security rules not removed" >&2
  exit 1
fi

if [ -f "$PATH_HEADER_DIR/customset.conf" ]; then
  echo "[Error] customset include still exists" >&2
  exit 1
fi

if [ ! -f "$PATH_HEADER_DIR/sharedset.conf" ]; then
  echo "[Error] shared header include removed unexpectedly" >&2
  exit 1
fi

cat >>"$BACKEND_PORTS_FILE" <<'EOF_RECREATE'
backend,example.com,10.0.1.10:9000,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_RECREATE

update_nginx_config

BACKENDS_CONF="$NGINX_HTTP_CONF_DIR/backends.conf"

if [ ! -f "$BACKENDS_CONF" ]; then
  echo "[Error] Nginx config not generated" >&2
  exit 1
fi

if grep -q 'customset' "$BACKENDS_CONF"; then
  echo "[Error] Stale path header include detected" >&2
  exit 1
fi

printf 'Clean-all regression checks passed.\n'
