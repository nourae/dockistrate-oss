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
source "$ROOT_DIR/lib/ports.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/global_settings.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/access_log.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/certs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_config_mutation_txn.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
CAPTURE_DIR="$STATE_DIR/pcaps"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
CERTS_DIR="$STATE_DIR/certs"
ACME_WEBROOT_DIR="$STATE_DIR/acme"
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
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
NGINX_CONTAINER_NAME="nginx-proxy"
NGINX_IMAGE="nginx:1.28.1"
DEFAULT_NETWORK="dockistrate-net"
INTERACTIVE=false

function capture_docker_logs() { :; }
function log_msg() { :; }
function create_backup() { :; }
function container_exists() { return 1; }
function create_nginx_config() {
  mkdir -p "$NGINX_CONFIG_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
  cat >"$NGINX_CONFIG_DIR/nginx.conf" <<'EOF_NGINX'
worker_processes  1;
events {}
http {}
EOF_NGINX
}
function update_nginx_config() { return 1; }

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_file_missing() {
  local path="$1"
  [ ! -e "$path" ] || fail_test "Expected path to be missing: $path"
}

function assert_file_exists() {
  local path="$1"
  [ -e "$path" ] || fail_test "Expected path to exist: $path"
}

function assert_same_file() {
  local left="$1" right="$2" message="$3"
  cmp -s "$left" "$right" || fail_test "$message"
}

function assert_csv_rows_or_missing() {
  local path="$1" header="$2" expected="$3" message="$4"
  if [ ! -e "$path" ]; then
    [ "$expected" -eq 0 ] || fail_test "$message"
    return 0
  fi
  csv_require_header "$path" "$header" >/dev/null 2>&1 || fail_test "$message"
  local row_count
  row_count="$(csv_data_row_count "$path" "$header")" || fail_test "$message"
  [ "$row_count" -eq "$expected" ] || fail_test "$message"
}

function run_expect_failure() {
  local label="$1"
  shift
  local status=0
  set +e
  ("$@" >/dev/null 2>&1)
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail_test "${label} succeeded unexpectedly"
  fi
}

function reset_common_state() {
  rm -rf "$STATE_DIR"
  mkdir -p \
    "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
    "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$CERTS_DIR" "$ACME_WEBROOT_DIR"

  ENABLE_AUTO_BACKUPS="true"
  BACKUP_RETENTION="0"
  ENABLE_BACKUP_COMPRESSION="true"
  HTTP_VERSION="http1.1"
  CLIENT_IP_HEADER="X-Forwarded-For"
  PROXY_IP_HEADER="X-Real-IP"
  TLS_PROTOCOLS="TLSv1.2 TLSv1.3"
  TLS_CIPHERS="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
  SECURITY_RULE_STATUS="403"
  ACL_STATUS="403"
  ACL_POLICY="deny"
  TRUSTED_PROXY_RANGES=""
  REAL_IP_RECURSIVE="on"
  NGINX_PULL_MODE="if-missing"
  NGINX_DOCKER_OPTS=""
  CERT_AUTOCONFIG_DISABLED=1

  save_config
  create_nginx_config
  bootstrap_config_runtime >/dev/null 2>&1 || fail_test "Failed to initialize baseline runtime state"
}

function write_backend_with_http_port() {
  cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,80,8000,http,none,no,off,,off,auto,,,,,,
EOF_PORTS
}

function create_uploaded_cert_inputs() {
  local prefix="$1"
  cat >"$TMP_ROOT/${prefix}_fullchain.pem" <<'EOF_CERT'
-----BEGIN CERTIFICATE-----
MIIBczCCAVmgAwIBAgIUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwDQYJKoZIhvcNAQEL
BQAwEjEQMA4GA1UEAwwHZXhhbXBsZTAeFw0yNjAzMDcxMjAwMDBaFw0yNzAzMDcxMjAw
MDBaMBIxEDAOBgNVBAMMB2V4YW1wbGUwXDANBgkqhkiG9w0BAQEFAANLADBIAkEAzNwE
z0VX4nHCqB6f+GO6zkRgZNpmjQe7YQDdyCjTiMQuuLHfoalGexiLRNvKcJsteVEh9Up7
X4jG3Ejj6inUeJ8V+QIDAQABo1MwUTAdBgNVHQ4EFgQUAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAwHwYDVR0jBBgwFoAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwDwYDVR0TAQH/
BAUwAwEB/zANBgkqhkiG9w0BAQsFAANBAJ0aKBslZx2drXr/7L0KleChX2NDVYqoQZnQ
plLWYwgd0CQpZK0s8AjtKoa6HgMHqmpYyqn1nVbWcv16O3MHuvk=
-----END CERTIFICATE-----
EOF_CERT
  cat >"$TMP_ROOT/${prefix}_privkey.pem" <<'EOF_KEY'
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDg
-----END PRIVATE KEY-----
EOF_KEY
}

# Scenario A: add_port_mapping rolls back appended state.
reset_common_state
write_backend_with_http_port
cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
run_expect_failure "add_port_mapping" add_port_mapping example.com 81 8000 http none no
assert_same_file "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig" "Port mapping rollback did not restore backend_ports.csv"

# Scenario B: remove_port_mapping rolls back deleted state.
reset_common_state
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,80,8000,http,none,no,off,,off,auto,,,,,,
port,example.com,,,,,81,8000,http,none,no,off,,off,auto,,,,,,
EOF_PORTS
cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
run_expect_failure "remove_port_mapping" remove_port_mapping example.com 81
assert_same_file "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig" "Port removal rollback did not restore backend_ports.csv"

# Scenario C: set_header removes a newly-created state file on rollback.
reset_common_state
cp "$CUSTOM_HEADERS_FILE" "$CUSTOM_HEADERS_FILE.orig"
run_expect_failure "set_header" set_header response X-Test value
assert_same_file "$CUSTOM_HEADERS_FILE" "$CUSTOM_HEADERS_FILE.orig" "Header rollback did not restore custom_headers.csv"

# Scenario D: add_security_rule removes a newly-created rules file on rollback.
reset_common_state
write_backend_with_http_port
run_expect_failure "add_security_rule" add_security_rule example.com 1 header User-Agent contains curl
assert_csv_rows_or_missing "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER" 0 "Security rule rollback did not restore an empty rules state"

# Scenario E: add_host_alias removes a newly-created alias file on rollback.
reset_common_state
write_backend_with_http_port
run_expect_failure "add_host_alias" add_host_alias www.example.com example.com
assert_csv_rows_or_missing "$BACKEND_ALIASES_FILE" "$STATE_BACKEND_ALIASES_HEADER" 0 "Alias rollback did not restore an empty alias state"

# Scenario F: set_acl_status restores the previous global settings file.
reset_common_state
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
run_expect_failure "set_acl_status" set_acl_status 429
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "ACL status rollback did not restore global_settings.csv"

# Scenario G: add_log_field restores the previous access log field file.
reset_common_state
_access_log_load_fields
cp "$ACCESS_LOG_FIELDS_FILE" "$ACCESS_LOG_FIELDS_FILE.orig"
run_expect_failure "add_log_field" add_log_field '$request_time'
assert_same_file "$ACCESS_LOG_FIELDS_FILE" "$ACCESS_LOG_FIELDS_FILE.orig" "Access log field rollback did not restore access_log_fields.csv"

# Scenario H: add_cert removes the new certificate directory on rollback.
reset_common_state
create_uploaded_cert_inputs "add"
run_expect_failure "add_cert" add_cert example.com 443 upload "$TMP_ROOT/add_fullchain.pem" "$TMP_ROOT/add_privkey.pem"
assert_file_missing "$CERTS_DIR/custom/live/example.com_443"

# Scenario I: remove_cert restores deleted certificate files on rollback.
reset_common_state
mkdir -p "$CERTS_DIR/custom/live/example.com_443"
printf 'old-fullchain\n' >"$CERTS_DIR/custom/live/example.com_443/fullchain.pem"
printf 'old-privkey\n' >"$CERTS_DIR/custom/live/example.com_443/privkey.pem"
cp "$CERTS_DIR/custom/live/example.com_443/fullchain.pem" "$TMP_ROOT/remove_fullchain.orig"
cp "$CERTS_DIR/custom/live/example.com_443/privkey.pem" "$TMP_ROOT/remove_privkey.orig"
run_expect_failure "remove_cert" remove_cert example.com 443
assert_file_exists "$CERTS_DIR/custom/live/example.com_443/fullchain.pem"
assert_file_exists "$CERTS_DIR/custom/live/example.com_443/privkey.pem"
assert_same_file "$CERTS_DIR/custom/live/example.com_443/fullchain.pem" "$TMP_ROOT/remove_fullchain.orig" "remove_cert rollback did not restore fullchain.pem"
assert_same_file "$CERTS_DIR/custom/live/example.com_443/privkey.pem" "$TMP_ROOT/remove_privkey.orig" "remove_cert rollback did not restore privkey.pem"

# Scenario J: replace_cert restores old provider material on rollback.
reset_common_state
mkdir -p "$CERTS_DIR/selfsigned/live/example.com_443"
printf 'old-selfsigned-fullchain\n' >"$CERTS_DIR/selfsigned/live/example.com_443/fullchain.pem"
printf 'old-selfsigned-privkey\n' >"$CERTS_DIR/selfsigned/live/example.com_443/privkey.pem"
cp "$CERTS_DIR/selfsigned/live/example.com_443/fullchain.pem" "$TMP_ROOT/replace_fullchain.orig"
cp "$CERTS_DIR/selfsigned/live/example.com_443/privkey.pem" "$TMP_ROOT/replace_privkey.orig"
create_uploaded_cert_inputs "replace"
run_expect_failure "replace_cert" replace_cert example.com 443 upload "$TMP_ROOT/replace_fullchain.pem" "$TMP_ROOT/replace_privkey.pem"
assert_file_exists "$CERTS_DIR/selfsigned/live/example.com_443/fullchain.pem"
assert_file_exists "$CERTS_DIR/selfsigned/live/example.com_443/privkey.pem"
assert_same_file "$CERTS_DIR/selfsigned/live/example.com_443/fullchain.pem" "$TMP_ROOT/replace_fullchain.orig" "replace_cert rollback did not restore the prior fullchain.pem"
assert_same_file "$CERTS_DIR/selfsigned/live/example.com_443/privkey.pem" "$TMP_ROOT/replace_privkey.orig" "replace_cert rollback did not restore the prior privkey.pem"
assert_file_missing "$CERTS_DIR/custom/live/example.com_443"

echo "config mutation transaction coverage passed."
