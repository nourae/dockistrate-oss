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

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function value_of() {
  local var_name="${1:-}"
  eval 'printf "%s\n" "${'"$var_name"':-}"'
}

function assert_header_shape() {
  local header_var="${1:-}" cols_var="${2:-}" header="" expected_cols="" field="" field_count=0
  local -a fields=()

  header="$(value_of "$header_var")"
  expected_cols="$(value_of "$cols_var")"
  [ -n "$header" ] || fail_test "${header_var} is empty"
  [ -n "$expected_cols" ] || fail_test "${cols_var} is empty"

  IFS=',' read -r -a fields <<<"$header"
  field_count="${#fields[@]}"
  [ "$field_count" -eq "$expected_cols" ] ||
    fail_test "${header_var} has ${field_count} fields but ${cols_var} is ${expected_cols}"

  for field in "${fields[@]}"; do
    [[ "$field" =~ ^[a-z][a-z0-9_]*$ ]] ||
      fail_test "${header_var} field '${field}' is not lower-snake-case"
    case "$field" in
    cert_ref | ws | loc | s[0-9]* | n[0-9]* | c[0-9]* | v[0-9]* | code | count | docker_opts | mtls_dir | type | name | value | header | policy | port | protocols | ciphers | field)
      fail_test "${header_var} still uses terse field '${field}'"
      ;;
    esac
  done
}

function assert_file_header() {
  local file="${1:-}" header_var="${2:-}" expected="" first_line=""
  expected="$(value_of "$header_var")"
  [ -f "$file" ] || fail_test "Expected runtime CSV file missing: $file"
  IFS= read -r first_line <"$file" || first_line=""
  first_line="${first_line%$'\r'}"
  [ "$first_line" = "$expected" ] ||
    fail_test "Header mismatch in $file: expected '${expected}', got '${first_line}'"
}

function assert_contains_header() {
  local file="${1:-}" header_var="${2:-}" header=""
  header="$(value_of "$header_var")"
  grep -Fq "$header" "$file" ||
    fail_test "$file does not mention ${header_var}: ${header}"
}

function assert_absent_literal() {
  local file="${1:-}" literal="${2:-}"
  if grep -Fq "$literal" "$file"; then
    fail_test "$file still contains stale CSV header literal: $literal"
  fi
}

schema_specs=(
  "STATE_GLOBAL_SETTINGS_HEADER:STATE_GLOBAL_SETTINGS_COLS"
  "STATE_BACKEND_PORTS_HEADER:STATE_BACKEND_PORTS_COLS"
  "STATE_BACKEND_ALIASES_HEADER:STATE_BACKEND_ALIASES_COLS"
  "STATE_DEDICATED_HOST_INHERITANCE_HEADER:STATE_DEDICATED_HOST_INHERITANCE_COLS"
  "STATE_CUSTOM_HEADERS_HEADER:STATE_CUSTOM_HEADERS_COLS"
  "STATE_BACKEND_HEADERS_HEADER:STATE_BACKEND_HEADERS_COLS"
  "STATE_BACKEND_HTTP_VERSIONS_HEADER:STATE_BACKEND_HTTP_VERSIONS_COLS"
  "STATE_PORT_TLS_PROTOCOLS_HEADER:STATE_PORT_TLS_PROTOCOLS_COLS"
  "STATE_PORT_TLS_CIPHERS_HEADER:STATE_PORT_TLS_CIPHERS_COLS"
  "STATE_NGINX_DIRECTIVES_HEADER:STATE_NGINX_DIRECTIVES_COLS"
  "STATE_BACKEND_MTLS_HEADER:STATE_BACKEND_MTLS_COLS"
  "STATE_BACKEND_CLIENT_IP_HEADERS_HEADER:STATE_BACKEND_CLIENT_IP_HEADERS_COLS"
  "STATE_BACKEND_PROXY_IP_HEADERS_HEADER:STATE_BACKEND_PROXY_IP_HEADERS_COLS"
  "STATE_BACKEND_DOCKER_OPTS_HEADER:STATE_BACKEND_DOCKER_OPTS_COLS"
  "STATE_BACKEND_ACL_POLICIES_HEADER:STATE_BACKEND_ACL_POLICIES_COLS"
  "STATE_BACKEND_ACL_STATUSES_HEADER:STATE_BACKEND_ACL_STATUSES_COLS"
  "STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER:STATE_BACKEND_SECURITY_RULE_STATUSES_COLS"
  "STATE_SECURITY_IP_RULES_HEADER:STATE_SECURITY_IP_RULES_COLS"
  "STATE_SECURITY_RULES_HEADER:STATE_SECURITY_RULES_COLS"
  "STATE_ACCESS_LOG_FIELDS_HEADER:STATE_ACCESS_LOG_FIELDS_COLS"
)

for spec in "${schema_specs[@]}"; do
  assert_header_shape "${spec%%:*}" "${spec#*:}"
done

tracked_csv="$(cd "$ROOT_DIR" && git ls-files '*.csv')"
[ -z "$tracked_csv" ] || fail_test "Tracked CSV files should not remain: ${tracked_csv}"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_csv_schema.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

bootstrap_config_runtime || fail_test "bootstrap_config_runtime failed"

runtime_specs=(
  "$GLOBAL_SETTINGS_FILE:STATE_GLOBAL_SETTINGS_HEADER"
  "$BACKEND_PORTS_FILE:STATE_BACKEND_PORTS_HEADER"
  "$BACKEND_ALIASES_FILE:STATE_BACKEND_ALIASES_HEADER"
  "$CONFIG_DIR/dedicated_host_inheritance.csv:STATE_DEDICATED_HOST_INHERITANCE_HEADER"
  "$CUSTOM_HEADERS_FILE:STATE_CUSTOM_HEADERS_HEADER"
  "$BACKEND_HEADERS_FILE:STATE_BACKEND_HEADERS_HEADER"
  "$BACKEND_HTTP_FILE:STATE_BACKEND_HTTP_VERSIONS_HEADER"
  "$PORT_TLS_PROTOCOLS_FILE:STATE_PORT_TLS_PROTOCOLS_HEADER"
  "$PORT_TLS_CIPHERS_FILE:STATE_PORT_TLS_CIPHERS_HEADER"
  "$NGINX_DIRECTIVES_FILE:STATE_NGINX_DIRECTIVES_HEADER"
  "$BACKEND_MTLS_FILE:STATE_BACKEND_MTLS_HEADER"
  "$BACKEND_CLIENT_IP_HEADER_FILE:STATE_BACKEND_CLIENT_IP_HEADERS_HEADER"
  "$BACKEND_PROXY_IP_HEADER_FILE:STATE_BACKEND_PROXY_IP_HEADERS_HEADER"
  "$BACKEND_DOCKER_OPTS_FILE:STATE_BACKEND_DOCKER_OPTS_HEADER"
  "$BACKEND_ACL_POLICY_FILE:STATE_BACKEND_ACL_POLICIES_HEADER"
  "$BACKEND_ACL_STATUS_FILE:STATE_BACKEND_ACL_STATUSES_HEADER"
  "$BACKEND_SECURITY_RULE_STATUS_FILE:STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER"
  "$SECURITY_IP_RULES_FILE:STATE_SECURITY_IP_RULES_HEADER"
  "$SECURITY_RULES_FILE:STATE_SECURITY_RULES_HEADER"
  "$ACCESS_LOG_FIELDS_FILE:STATE_ACCESS_LOG_FIELDS_HEADER"
)

for spec in "${runtime_specs[@]}"; do
  assert_file_header "${spec%%:*}" "${spec#*:}"
done

docs_md="$ROOT_DIR/docs/function-reference.md"
docs_html="$ROOT_DIR/docs/function-reference.html"
readme="$ROOT_DIR/README.md"

for spec in "${schema_specs[@]}"; do
  header_var="${spec%%:*}"
  assert_contains_header "$docs_md" "$header_var"
  assert_contains_header "$docs_html" "$header_var"
done
assert_contains_header "$readme" STATE_BACKEND_PORTS_HEADER

stale_literals=(
  "record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,cert_ref,ws,redirect_flag,redirect_code"
  "scope,domain,listen_port,mode,directive,value"
  "enabled,domain,mode,code,count"
  "enabled,domain,scope,action,ip,code"
  "key,docker_opts"
  "type,name,value"
  "port,protocols"
  "port,ciphers"
  "header \`field\`"
)

for literal in "${stale_literals[@]}"; do
  assert_absent_literal "$docs_md" "$literal"
  assert_absent_literal "$docs_html" "$literal"
done

echo "[tests] csv_schema_alignment.sh: PASS"
