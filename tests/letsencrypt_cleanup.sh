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

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR" \
  "$CERTS_DIR"

LE_BASE="$CERTS_DIR/letsencrypt"
mkdir -p "$LE_BASE/live" "$LE_BASE/archive" "$LE_BASE/renewal"

write_le_material() {
  local source_domain="${1:?}"
  local consumer_port="${2:-}"

  mkdir -p "$LE_BASE/live/${source_domain}"
  printf 'shared-fullchain-%s\n' "$source_domain" >"$LE_BASE/live/${source_domain}/fullchain.pem"
  printf 'shared-privkey-%s\n' "$source_domain" >"$LE_BASE/live/${source_domain}/privkey.pem"
  mkdir -p "$LE_BASE/archive/${source_domain}"
  printf 'archive-%s\n' "$source_domain" >"$LE_BASE/archive/${source_domain}/cert1.pem"
  cat >"$LE_BASE/renewal/${source_domain}.conf" <<EOF_SHARED_RENEWAL
# renewal config for ${source_domain}
EOF_SHARED_RENEWAL

  if [ -n "$consumer_port" ]; then
    mkdir -p "$LE_BASE/live/${source_domain}_${consumer_port}"
    printf 'consumer-fullchain-%s-%s\n' "$source_domain" "$consumer_port" >"$LE_BASE/live/${source_domain}_${consumer_port}/fullchain.pem"
    printf 'consumer-privkey-%s-%s\n' "$source_domain" "$consumer_port" >"$LE_BASE/live/${source_domain}_${consumer_port}/privkey.pem"
    mkdir -p "$LE_BASE/archive/${source_domain}_${consumer_port}"
    printf 'archive-%s-%s\n' "$source_domain" "$consumer_port" >"$LE_BASE/archive/${source_domain}_${consumer_port}/cert1.pem"
    cat >"$LE_BASE/renewal/${source_domain}_${consumer_port}.conf" <<EOF_PORT_RENEWAL
# renewal config for ${source_domain}_${consumer_port}
EOF_PORT_RENEWAL
  fi
}

write_le_material example.com 8443
write_le_material example.com 443
write_le_material other.com ""

cat >"$BACKEND_PORTS_FILE" <<'EOF_REMOVE_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,443,8000,https,letsencrypt/live/example.com_443,no,off,,off,auto,,,,,,
EOF_REMOVE_PORTS

remove_cert example.com 8443

for path in \
  "$LE_BASE/live/example.com_8443" \
  "$LE_BASE/archive/example.com_8443" \
  "$LE_BASE/renewal/example.com_8443.conf"; do
  if [ -e "$path" ]; then
    echo "[Error] remove-cert left behind per-port consumer copy $path" >&2
    exit 1
  fi
done

for path in \
  "$LE_BASE/live/example.com" \
  "$LE_BASE/archive/example.com" \
  "$LE_BASE/renewal/example.com.conf" \
  "$LE_BASE/live/example.com_443" \
  "$LE_BASE/archive/example.com_443" \
  "$LE_BASE/renewal/example.com_443.conf"; do
  if [ ! -e "$path" ]; then
    echo "[Error] remove-cert removed shared or still-referenced assets $path" >&2
    exit 1
  fi
done

for path in \
  "$LE_BASE/live/other.com" \
  "$LE_BASE/archive/other.com" \
  "$LE_BASE/renewal/other.com.conf"; do
  if [ ! -e "$path" ]; then
    echo "[Error] remove-cert removed unrelated $path" >&2
    exit 1
  fi
done

rm -rf "$LE_BASE/live/example.com_443" "$LE_BASE/archive/example.com_443"
rm -f "$LE_BASE/renewal/example.com_443.conf"
write_le_material example.com 443

cat >"$BACKEND_PORTS_FILE" <<'EOF_CLEAN_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,443,8000,https,letsencrypt/live/example.com_443,no,off,,off,auto,,,,,,
backend,shared.example.net,10.0.0.6:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,shared.example.net,,,,,9443,8000,https,letsencrypt/live/example.com,no,off,,off,auto,,,,,,
EOF_CLEAN_PORTS

clean_all example.com

for path in \
  "$LE_BASE/live/example.com_443" \
  "$LE_BASE/archive/example.com_443" \
  "$LE_BASE/renewal/example.com_443.conf"; do
  if [ -e "$path" ]; then
    echo "[Error] clean-all left behind removed domain consumer copy $path" >&2
    exit 1
  fi
done

for path in \
  "$LE_BASE/live/example.com" \
  "$LE_BASE/archive/example.com" \
  "$LE_BASE/renewal/example.com.conf"; do
  if [ ! -e "$path" ]; then
    echo "[Error] clean-all removed shared Let's Encrypt source assets still needed by another consumer: $path" >&2
    exit 1
  fi
done

for path in \
  "$LE_BASE/live/other.com" \
  "$LE_BASE/archive/other.com" \
  "$LE_BASE/renewal/other.com.conf"; do
  if [ ! -e "$path" ]; then
    echo "[Error] clean-all removed unrelated $path" >&2
    exit 1
  fi
done


write_le_material orphaned.example.com ""

cat >"$BACKEND_PORTS_FILE" <<'EOF_ORPHANED_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,orphaned.example.com,10.0.0.7:8000,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_ORPHANED_PORTS

clean_all orphaned.example.com

for path in   "$LE_BASE/live/orphaned.example.com"   "$LE_BASE/archive/orphaned.example.com"   "$LE_BASE/renewal/orphaned.example.com.conf"; do
  if [ -e "$path" ]; then
    echo "[Error] clean-all left behind orphaned shared Let's Encrypt source assets: $path" >&2
    exit 1
  fi
done

printf "Let's Encrypt cleanup regression checks passed.\n"
