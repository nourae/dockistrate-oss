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
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
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

# shellcheck source=helpers/global_csv.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/global_csv.sh"
test_global_csv_seed "$GLOBAL_SETTINGS_FILE" \
  ENABLE_AUTO_BACKUPS false BACKUP_RETENTION 0 ENABLE_BACKUP_COMPRESSION false \
  HTTP_VERSION "$HTTP_VERSION" CLIENT_IP_HEADER "$CLIENT_IP_HEADER" PROXY_IP_HEADER "$PROXY_IP_HEADER" \
  TLS_PROTOCOLS "$TLS_PROTOCOLS" TLS_CIPHERS "$TLS_CIPHERS" SECURITY_RULE_STATUS "$SECURITY_RULE_STATUS" \
  ACL_STATUS "$ACL_STATUS" ACL_POLICY "$ACL_POLICY" TRUSTED_PROXY_RANGES "$TRUSTED_PROXY_RANGES" \
  REAL_IP_RECURSIVE "$REAL_IP_RECURSIVE"


# shellcheck disable=SC1091
source "$ROOT_DIR/lib/domain_config.sh"
function domain_config_certificate_layout() { [ "$FIXTURE_LAYOUT" = current ]; }
function fixture_authority() {
  if [ "$FIXTURE_LAYOUT" = current ]; then printf '%s/domains/%s/mtls' "$STATE_DIR" "$1"
  else printf '%s/mtls/%s' "$CERTS_DIR" "$1"; fi
}
function fixture_files() {
  local identity="$1" file="" owned=""
  owned="$(fixture_authority "$identity")"
  mkdir -p "$owned" "$STATE_DIR/domains/$identity/generated/nginx"
  printf 'private sentinel %s\n' "$identity" >"$owned/sentinel"
  for file in "$SECURITY_IP_DIR/$identity.inc" "$SECURITY_IP_STREAM_DIR/$identity.inc" \
    "$STATE_DIR/domains/$identity/generated/nginx/acl-http.inc" "$STATE_DIR/domains/$identity/generated/nginx/acl-stream.inc"; do
    printf 'include sentinel %s\n' "$identity" >"$file"
  done
}
function assert_preserved() {
  local identity="$1" file=""
  for file in "$(fixture_authority "$identity")/sentinel" "$SECURITY_IP_DIR/$identity.inc" "$SECURITY_IP_STREAM_DIR/$identity.inc" \
    "$STATE_DIR/domains/$identity/generated/nginx/acl-http.inc" "$STATE_DIR/domains/$identity/generated/nginx/acl-stream.inc"; do
    [ -s "$file" ] || { printf '[FAIL] Missing preserved artifact: %s\n' "$file" >&2; exit 1; }
  done
}

# Real ownership lookup, canonical guards, map removal, and artifact cleanup;
# no runtime calls or certificate issuance. Fixture layout is selected explicitly.
for FIXTURE_LAYOUT in legacy current; do
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  for identity in parent.example.com other.example.com backend-collision.example.com; do
    printf 'backend,%s,10.0.0.5:80,audit-net,,,,,,,,,,,,,,,,,\n' "$identity" >>"$BACKEND_PORTS_FILE"
  done
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
    'dedicated,inherited.example.com,parent.example.com' \
    'dedicated,backend-collision.example.com,parent.example.com' \
    'dedicated,alias-collision.example.com,parent.example.com' \
    'alias,alias-collision.example.com,other.example.com' >"$BACKEND_ALIASES_FILE"
  parent_owned="$(fixture_authority parent.example.com)"
  mkdir -p "$parent_owned"
  printf 'parent authority\n' >"$parent_owned/sentinel"
  printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" "parent.example.com,$parent_owned" >"$BACKEND_MTLS_FILE"
  effective="" effective_owner="" selected=""
  _mtls_resolve_effective_mapping effective effective_owner inherited.example.com
  [ "$effective" = "$parent_owned" ] && [ "$effective_owner" = parent.example.com ]
  _removed_identity_mtls_target selected inherited.example.com
  [ "$selected" != "$parent_owned" ] || { echo '[FAIL] Destructive target resolved inherited authority'; exit 1; }
  remove_dedicated_host_alias inherited.example.com
  _removed_identity_cleanup_artifacts inherited.example.com "$selected"
  [ -s "$parent_owned/sentinel" ]
  for identity in backend-collision.example.com alias-collision.example.com; do
    fixture_files "$identity"
    _removed_identity_mtls_target selected "$identity"
    remove_dedicated_host_alias "$identity"
    _removed_identity_cleanup_artifacts "$identity" "$selected"
    assert_preserved "$identity"
  done
  backend_exists backend-collision.example.com
  alias_exists alias-collision.example.com
  printf '[PASS] %s inherited trust and surviving backend/alias collisions preserved\n' "$FIXTURE_LAYOUT"
done
