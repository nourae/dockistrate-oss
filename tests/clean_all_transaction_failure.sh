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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_clean_all_fail.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
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

INTERACTIVE=false
SKIP_DOCKER_CHECKS=true

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$CERTS_DIR/mtls/example.com"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,18180,8000,http,none,yes,off,,off,auto,,,,,,
path,example.com,,,/app,customset,18180,,,,inherit,off,,,,prefix,100,,none,-,auto
EOF_PORTS
cat >"$BACKEND_HEADERS_FILE" <<'EOF_BACKEND_HEADERS'
domain,header_type,header_name,header_value
example.com,response,X-Test,one
EOF_BACKEND_HEADERS
cat >"$BACKEND_HTTP_FILE" <<'EOF_BACKEND_HTTP'
domain,http_version
example.com,http2
EOF_BACKEND_HTTP
cat >"$BACKEND_MTLS_FILE" <<EOF_BACKEND_MTLS
domain,mtls_directory
example.com,$CERTS_DIR/mtls/example.com
EOF_BACKEND_MTLS
cat >"$BACKEND_CLIENT_IP_HEADER_FILE" <<'EOF_CLIENT_IP'
domain,client_ip_header_name
example.com,X-Forwarded-For
EOF_CLIENT_IP
cat >"$BACKEND_PROXY_IP_HEADER_FILE" <<'EOF_PROXY_IP'
domain,proxy_ip_header_name
example.com,X-Real-IP
EOF_PROXY_IP
cat >"$BACKEND_DOCKER_OPTS_FILE" <<'EOF_DOCKER_OPTS'
key,docker_options
backend:example.com,--cpus 1
EOF_DOCKER_OPTS
cat >"$BACKEND_ACL_POLICY_FILE" <<'EOF_ACL_POLICY'
domain,acl_policy
example.com,allow
EOF_ACL_POLICY
cat >"$BACKEND_ACL_STATUS_FILE" <<'EOF_ACL_STATUS'
domain,acl_status_code
example.com,403
EOF_ACL_STATUS
cat >"$BACKEND_SECURITY_RULE_STATUS_FILE" <<'EOF_SECURITY_RULE_STATUS'
domain,security_rule_status_code
example.com,429
EOF_SECURITY_RULE_STATUS
printf '%s\n' "enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location" >"$SECURITY_RULES_DB"
cat >"$SECURITY_IP_RULES_DB" <<'EOF_SECURITY_IP'
enabled,domain,scope,action,ip_value,status_code
1,example.com,l7,allow,127.0.0.1/32,200
EOF_SECURITY_IP
cat >"$PORT_TLS_PROTOCOLS_FILE" <<'EOF_TLS_PROTOCOLS'
listen_port,tls_protocols
443,TLSv1.2 TLSv1.3
EOF_TLS_PROTOCOLS
cat >"$PORT_TLS_CIPHERS_FILE" <<'EOF_TLS_CIPHERS'
listen_port,tls_ciphers
443,HIGH:!aNULL
EOF_TLS_CIPHERS
touch "$PATH_HEADER_DIR/customset.conf"
touch "$CERTS_DIR/mtls/example.com/ca.crt"

for file in \
  "$BACKEND_PORTS_FILE" \
  "$BACKEND_HEADERS_FILE" \
  "$BACKEND_HTTP_FILE" \
  "$BACKEND_MTLS_FILE" \
  "$BACKEND_CLIENT_IP_HEADER_FILE" \
  "$BACKEND_PROXY_IP_HEADER_FILE" \
  "$BACKEND_DOCKER_OPTS_FILE" \
  "$BACKEND_ACL_POLICY_FILE" \
  "$BACKEND_ACL_STATUS_FILE" \
  "$BACKEND_SECURITY_RULE_STATUS_FILE" \
  "$SECURITY_RULES_DB" \
  "$SECURITY_IP_RULES_DB" \
  "$PORT_TLS_PROTOCOLS_FILE" \
  "$PORT_TLS_CIPHERS_FILE"; do
  cp "$file" "${file}.orig"
done

FAIL_MTLS_DIR="$CERTS_DIR/mtls/example.com"
function safe_rm_f() {
  local target="${1:-}"
  rm -f "$target"
}
function safe_rm_rf() {
  local target="${1:-}"
  case "$target" in
  */mtls/example.com)
    echo "[Error] simulated safe-delete guard rejection for ${target}" >&2
    return 1
    ;;
  esac
  rm -rf "$target"
}

set +e
output="$(clean_all example.com 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] clean_all succeeded unexpectedly." >&2
  exit 1
fi
if ! grep -Fq "failed. Rolled back." <<<"$output"; then
  echo "[Error] Expected rollback message from clean_all failure." >&2
  exit 1
fi

for file in \
  "$BACKEND_PORTS_FILE" \
  "$BACKEND_HEADERS_FILE" \
  "$BACKEND_HTTP_FILE" \
  "$BACKEND_MTLS_FILE" \
  "$BACKEND_CLIENT_IP_HEADER_FILE" \
  "$BACKEND_PROXY_IP_HEADER_FILE" \
  "$BACKEND_DOCKER_OPTS_FILE" \
  "$BACKEND_ACL_POLICY_FILE" \
  "$BACKEND_ACL_STATUS_FILE" \
  "$BACKEND_SECURITY_RULE_STATUS_FILE" \
  "$SECURITY_RULES_DB" \
  "$SECURITY_IP_RULES_DB" \
  "$PORT_TLS_PROTOCOLS_FILE" \
  "$PORT_TLS_CIPHERS_FILE"; do
  if ! cmp -s "$file" "${file}.orig"; then
    echo "[Error] Rollback did not restore $(basename "$file")." >&2
    exit 1
  fi
done

if [ ! -d "$FAIL_MTLS_DIR" ]; then
  echo "[Error] Rollback did not restore mTLS directory." >&2
  exit 1
fi

printf 'Clean-all transaction rollback checks passed.\n'
