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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_backend_missing_container.XXXXXX")"
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
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"

INTERACTIVE=false

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$CERTS_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS

cat >"$BACKEND_HEADERS_FILE" <<'EOF_HEADERS'
domain,header_type,header_name,header_value
EOF_HEADERS

cat >"$BACKEND_HTTP_FILE" <<'EOF_HTTP'
domain,http_version
EOF_HTTP

cat >"$BACKEND_MTLS_FILE" <<'EOF_MTLS'
domain,mtls_directory
EOF_MTLS

cat >"$BACKEND_CLIENT_IP_HEADER_FILE" <<'EOF_CLIENT'
domain,client_ip_header_name
EOF_CLIENT

cat >"$BACKEND_PROXY_IP_HEADER_FILE" <<'EOF_PROXY'
domain,proxy_ip_header_name
EOF_PROXY

cat >"$BACKEND_ACL_POLICY_FILE" <<'EOF_ACL'
domain,acl_policy
EOF_ACL

cat >"$BACKEND_ACL_STATUS_FILE" <<'EOF_ACL_STATUS'
domain,acl_status_code
EOF_ACL_STATUS

cat >"$BACKEND_SECURITY_RULE_STATUS_FILE" <<'EOF_SEC_STATUS'
domain,security_rule_status_code
EOF_SEC_STATUS

cat >"$SECURITY_RULES_DB" <<'EOF_SEC_RULES'
enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location
EOF_SEC_RULES

cat >"$SECURITY_IP_RULES_DB" <<'EOF_SEC_IPS'
enabled,domain,scope,action,ip_value,status_code
EOF_SEC_IPS

cat >"$BACKEND_DOCKER_OPTS_FILE" <<'EOF_DOCKER_OPTS'
key,docker_options
EOF_DOCKER_OPTS

container_exists_calls=0
docker_rm_marker="$TMP_ROOT/docker-rm-called"

function container_exists() {
  container_exists_calls=$((container_exists_calls + 1))
  [ "$container_exists_calls" -eq 1 ]
}

function docker() {
  if [ "${1:-}" = "rm" ]; then
    : >"$docker_rm_marker"
    return 1
  fi
  return 0
}

function create_backup() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() { :; }
function log_msg() { :; }

output="$(remove_backend example.com 2>&1)"

if [ -f "$docker_rm_marker" ]; then
  echo "[Error] remove_backend attempted docker rm even though the container was already absent before final removal." >&2
  exit 1
fi

if ! printf '%s' "$output" | grep -Fq "already absent before final removal"; then
  echo "[Error] Expected remove_backend to report that the backend container was already absent before final removal." >&2
  exit 1
fi

if grep -Fq "backend,example.com," "$BACKEND_PORTS_FILE"; then
  echo "[Error] remove_backend should still remove backend config when the container disappears before final removal." >&2
  exit 1
fi

echo "remove_backend tolerates the backend container disappearing before final removal."
