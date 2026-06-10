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

FAILURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remove_backend_transaction_failure.d"
if [ -d "$FAILURE_DIR" ]; then
  for stub_file in "$FAILURE_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$stub_file"
  done
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_backend_fail.XXXXXX")"
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
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha1"

INTERACTIVE=false

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$CERTS_DIR" "$CERTS_DIR/mtls"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,8443,9443,https,none,yes,off,,off,auto,,,,,,
EOF_PORTS

cat >"$BACKEND_HEADERS_FILE" <<'EOF_HEADERS'
domain,header_type,header_name,header_value
example.com,response,X-Test,one
EOF_HEADERS

cat >"$BACKEND_HTTP_FILE" <<'EOF_HTTP'
domain,http_version
example.com,http2
EOF_HTTP

MTLS_DIR="$CERTS_DIR/mtls/example.com"
mkdir -p "$MTLS_DIR"
touch "$MTLS_DIR/ca.crt"
cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,$MTLS_DIR
EOF_MTLS

cat >"$BACKEND_CLIENT_IP_HEADER_FILE" <<'EOF_CLIENT'
domain,client_ip_header_name
example.com,X-Forwarded-For
EOF_CLIENT

cat >"$BACKEND_PROXY_IP_HEADER_FILE" <<'EOF_PROXY'
domain,proxy_ip_header_name
example.com,X-Real-IP
EOF_PROXY

cat >"$BACKEND_ACL_POLICY_FILE" <<'EOF_ACL'
domain,acl_policy
example.com,deny
EOF_ACL

cat >"$BACKEND_ACL_STATUS_FILE" <<'EOF_ACL_STATUS'
domain,acl_status_code
example.com,403
EOF_ACL_STATUS

cat >"$BACKEND_SECURITY_RULE_STATUS_FILE" <<'EOF_SEC_STATUS'
domain,security_rule_status_code
example.com,429
EOF_SEC_STATUS

cat >"$SECURITY_RULES_DB" <<'EOF_SEC_RULES'
enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location
EOF_SEC_RULES

cat >"$SECURITY_IP_RULES_DB" <<'EOF_SEC_IPS'
enabled,domain,scope,action,ip_value,status_code
1,example.com,l7,allow,10.0.0.0/24,200
EOF_SEC_IPS

cat >"$PORT_TLS_PROTOCOLS_FILE" <<'EOF_PROTO'
listen_port,tls_protocols
8443,TLSv1.2 TLSv1.3
EOF_PROTO

cat >"$PORT_TLS_CIPHERS_FILE" <<'EOF_CIPHERS'
listen_port,tls_ciphers
8443,HIGH:!aNULL
EOF_CIPHERS

cp "$BACKEND_HEADERS_FILE" "$BACKEND_HEADERS_FILE.orig"
cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
cp "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"
cp "$PORT_TLS_PROTOCOLS_FILE" "$PORT_TLS_PROTOCOLS_FILE.orig"
cp "$PORT_TLS_CIPHERS_FILE" "$PORT_TLS_CIPHERS_FILE.orig"
cp "$BACKEND_HTTP_FILE" "$BACKEND_HTTP_FILE.orig"
cp "$BACKEND_CLIENT_IP_HEADER_FILE" "$BACKEND_CLIENT_IP_HEADER_FILE.orig"
cp "$BACKEND_PROXY_IP_HEADER_FILE" "$BACKEND_PROXY_IP_HEADER_FILE.orig"
cp "$BACKEND_ACL_POLICY_FILE" "$BACKEND_ACL_POLICY_FILE.orig"
cp "$BACKEND_ACL_STATUS_FILE" "$BACKEND_ACL_STATUS_FILE.orig"
cp "$BACKEND_SECURITY_RULE_STATUS_FILE" "$BACKEND_SECURITY_RULE_STATUS_FILE.orig"
cp "$SECURITY_RULES_DB" "$SECURITY_RULES_DB.orig"
cp "$SECURITY_IP_RULES_DB" "$SECURITY_IP_RULES_DB.orig"

set +e
(remove_backend example.com)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] remove_backend succeeded unexpectedly" >&2
  exit 1
fi

for file in \
  "$BACKEND_HEADERS_FILE" \
  "$BACKEND_PORTS_FILE" \
  "$BACKEND_MTLS_FILE" \
  "$PORT_TLS_PROTOCOLS_FILE" \
  "$PORT_TLS_CIPHERS_FILE" \
  "$BACKEND_HTTP_FILE" \
  "$BACKEND_CLIENT_IP_HEADER_FILE" \
  "$BACKEND_PROXY_IP_HEADER_FILE" \
  "$BACKEND_ACL_POLICY_FILE" \
  "$BACKEND_ACL_STATUS_FILE" \
  "$BACKEND_SECURITY_RULE_STATUS_FILE" \
  "$SECURITY_RULES_DB" \
  "$SECURITY_IP_RULES_DB"; do
  if ! cmp -s "$file" "${file}.orig"; then
    echo "[Error] Rollback did not restore $(basename "$file")" >&2
    exit 1
  fi
done

if [ ! -d "$MTLS_DIR" ]; then
  echo "[Error] mTLS directory was removed despite rollback" >&2
  exit 1
fi

exit 0
