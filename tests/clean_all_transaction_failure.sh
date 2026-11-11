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
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
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
FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha256"

INTERACTIVE=false
SKIP_DOCKER_CHECKS=true
ENABLE_AUTO_BACKUPS=false

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$CERTS_DIR/mtls/example.com"

# Recovery reloads persisted settings before restoring runtime containers.
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"

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
domain,docker_options
example.com,--cpus 1
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
printf '%s\n' "enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location,action" >"$SECURITY_RULES_DB"
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
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'dedicated,admin.example.com,example.com' 'alias,alias.example.com,example.com' >"$BACKEND_ALIASES_FILE"
mkdir -p "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR"
for owner in example.com admin.example.com alias.example.com; do
  mkdir -p "$CERTS_DIR/mtls/$owner"
  printf 'owned %s\n' "$owner" >"$CERTS_DIR/mtls/$owner/sentinel"
  printf 'HTTP ACL %s\n' "$owner" >"$SECURITY_IP_DIR/$owner.inc"
  printf 'stream ACL %s\n' "$owner" >"$SECURITY_IP_STREAM_DIR/$owner.inc"
done

for file in \
  "$BACKEND_PORTS_FILE" \
  "$BACKEND_ALIASES_FILE" \
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
FAIL_CLEAN_MTLS=true
eval "$(declare -f _mtls_remove_dir_if_exists | sed '1s/_mtls_remove_dir_if_exists/_test_real_remove_mtls/')"
function safe_rm_f() {
  local target="${1:-}"
  rm -f "$target"
}
function safe_rm_rf() {
  local target="${1:-}"
  rm -rf "$target"
}
function _mtls_remove_dir_if_exists() {
  local target="${1:-}"
  if [ "$FAIL_CLEAN_MTLS" = false ]; then
    _test_real_remove_mtls "$target"
    return $?
  fi
  case "$target" in
  */mtls/example.com)
    echo "[Error] simulated mTLS owner-guard rejection for ${target}" >&2
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
  "$BACKEND_ALIASES_FILE" \
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

# Fail after authorities and both ACL contexts were actually deleted. This
# exercises the direct call's own transaction, without the domain dispatcher.
FAIL_CLEAN_MTLS=false
function update_nginx_config() {
  [ "${SKIP_UPDATE_NGINX_CONFIG:-false}" != true ] || return 0
  local owner="" artifact=""
  for owner in example.com admin.example.com alias.example.com; do
    for artifact in "$CERTS_DIR/mtls/$owner" "$SECURITY_IP_DIR/$owner.inc" "$SECURITY_IP_STREAM_DIR/$owner.inc"; do
      [ ! -e "$artifact" ] || { printf '[Error] Artifact survived before late failure: %s\n' "$artifact" >&2; return 1; }
    done
  done
  : >"$TMP_ROOT/late-failure-reached"
  return 1
}
set +e
output="$(clean_all example.com 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] && [ -f "$TMP_ROOT/late-failure-reached" ] || { echo "$output" >&2; echo '[Error] Did not reach failure after cleanup' >&2; exit 1; }
for file in "$BACKEND_PORTS_FILE" "$BACKEND_ALIASES_FILE" "$BACKEND_MTLS_FILE"; do
  cmp -s "$file" "$file.orig" || { echo '[Error] Late rollback lost configuration' >&2; exit 1; }
done
for owner in example.com admin.example.com alias.example.com; do
  for artifact in "$CERTS_DIR/mtls/$owner/sentinel" "$SECURITY_IP_DIR/$owner.inc" "$SECURITY_IP_STREAM_DIR/$owner.inc"; do
    [ -s "$artifact" ] || { printf '[Error] Late rollback lost artifact: %s\n' "$artifact" >&2; exit 1; }
  done
done
printf 'Clean-all transaction rollback before and after owned artifact deletion checks passed.\n'
