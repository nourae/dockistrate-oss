#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backends/common.sh"
source "$ROOT_DIR/lib/domain_config/generated.sh"
source "$ROOT_DIR/tests/helpers/global_csv.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_shared_csv.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; CONFIG_DIR="$STATE_DIR/config"; DOMAINS_DIR="$STATE_DIR/domains"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
mkdir -p "$CONFIG_DIR"
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

test_global_csv_seed "$GLOBAL_SETTINGS_FILE" HTTP_VERSION http1.1 CLIENT_IP_HEADER '' \
  PROXY_IP_HEADER '' TRUSTED_PROXY_RANGES '' NGINX_DOCKER_OPTS '--label "label=a,b"' \
  EXTENSION_SETTING 'literal,"quoted",value'
load_config
[ "$HTTP_VERSION" = http1.1 ] && [ -z "$CLIENT_IP_HEADER$PROXY_IP_HEADER$TRUSTED_PROXY_RANGES" ] || fail_test 'Global blank values lost'
[ "${GLOBAL_SETTINGS_EXTENSION_VALUES[0]}" = 'literal,"quoted",value' ] || fail_test 'Extension value lost'

# Reverse every column, including the inert extension, and use CRLF records.
{ IFS= read -r header; IFS= read -r record; } <"$GLOBAL_SETTINGS_FILE"
csv_parse_line "$header"; original_headers=("${CSV_FIELDS[@]}")
csv_parse_line "$record"; original_values=("${CSV_FIELDS[@]}")
reversed_headers=(); reversed_values=()
for ((index = ${#original_headers[@]} - 1; index >= 0; index--)); do
  reversed_headers+=("${original_headers[index]}")
  reversed_values+=("${original_values[index]}")
done
printf '%s\r\n' "$(csv_join_row "${reversed_headers[@]}")" "$(csv_join_row "${reversed_values[@]}")" >"$GLOBAL_SETTINGS_FILE"
load_config
[ "$HTTP_VERSION" = http1.1 ] && [ "$NGINX_DOCKER_OPTS" = '--label "label=a,b"' ] || fail_test 'Reordered global columns changed values'
_save_config_atomic_write
load_config
[ "${GLOBAL_SETTINGS_EXTENSION_HEADERS[0]}" = EXTENSION_SETTING ] &&
  [ "${GLOBAL_SETTINGS_EXTENSION_VALUES[0]}" = 'literal,"quoted",value' ] || fail_test 'Save dropped extension'
[ "$(wc -l <"$GLOBAL_SETTINGS_FILE" | tr -d ' ')" = 2 ] || fail_test 'Global writer did not create one record'
unset VISIBILITY_POLICY
CLIENT_IP_HEADER=''
_save_config_atomic_write
load_config
[ "$VISIBILITY_POLICY" = "$DEFAULT_VISIBILITY_POLICY" ] || fail_test 'Unset global setting did not inherit its default'
[ -z "$CLIENT_IP_HEADER" ] || fail_test 'Writer default replaced an explicit blank setting'
cp "$GLOBAL_SETTINGS_FILE" "$WORK/valid.csv"

for invalid in duplicate_header case_collision missing_header extra_record header_only bad_width; do
  { IFS= read -r header; IFS= read -r record; } <"$WORK/valid.csv"
  case "$invalid" in
  duplicate_header) printf '%s,http_version\n%s,http2\n' "$header" "$record" ;;
  case_collision) printf '%s,HTTP_VERSION\n%s,http2\n' "$header" "$record" ;;
  missing_header) printf '%s\n%s\n' "${header#*,}" "${record#*,}" ;;
  extra_record) printf '%s\n%s\n%s\n' "$header" "$record" "$record" ;;
  header_only) printf '%s\n' "$header" ;;
  bad_width) printf '%s\n%s,extra\n' "$header" "$record" ;;
  esac >"$GLOBAL_SETTINGS_FILE"
  HTTP_VERSION=http1.0
  if load_config >"$WORK/error" 2>&1; then fail_test "Accepted $invalid"; fi
  [ "$HTTP_VERSION" = http1.0 ] || fail_test "Published partial globals for $invalid"
done

# Matching a caller-provided schema never makes empty or duplicate field names
# valid. These checks also cover the canonical-header reader's common path.
for schema in 'field,field' ',field' 'field,' $'field,bad\rname'; do
  printf '%s\none,two\n' "$schema" >"$WORK/invalid-schema.csv"
  if csv_read_records "$WORK/invalid-schema.csv" "$schema" _state_csv_record_noop singleton >"$WORK/error" 2>&1; then
    fail_test 'Matching invalid field names bypassed CSV validation'
  fi
done

# Width errors identify the physical row and parsed column counts without
# printing operator values. Quoted commas count as part of one cell.
schema='rule_id,order,enabled,action,mode,status_code,reason,source_location'
for header in "$schema" 'reason,source_location,status_code,mode,action,enabled,order,rule_id'; do
  for width in 6 9; do
    printf '%s\n' "$header" >"$WORK/invalid-width.csv"
    case "$width" in
    6) printf '%s\n' 'rule-invalid,1,1,require,single,499' ;;
    9) printf '%s\n' 'rule-invalid,1,1,require,single,499,"private,reason",location,extra' ;;
    esac >>"$WORK/invalid-width.csv"
    cp "$WORK/invalid-width.csv" "$WORK/invalid-width.before"
    if csv_read_records "$WORK/invalid-width.csv" "$schema" _state_csv_record_noop >"$WORK/error" 2>&1; then
      fail_test 'Accepted a security rule with invalid column count'
    fi
    grep -Fq "invalid-width.csv:2: Invalid CSV record width (expected 8 columns, found $width)" "$WORK/error" ||
      fail_test 'Width diagnostic omitted file, row, or parsed column counts'
    ! grep -Fq 'private,reason' "$WORK/error" || fail_test 'Width diagnostic exposed a cell value'
    cmp -s "$WORK/invalid-width.csv" "$WORK/invalid-width.before" || fail_test 'Rejected row changed source bytes'
  done
done

# Explicit conversion preserves old empty values and extensions, without
# authorizing ordinary reads of legacy state or editing its source file.
printf 'setting_key,setting_value\nHTTP_VERSION,http1.1\nCLIENT_IP_HEADER,\nEXTENSION_SETTING,"a,b"\n' >"$WORK/legacy.csv"
cp "$WORK/legacy.csv" "$WORK/legacy.before"
_global_settings_convert_legacy "$WORK/legacy.csv" "$GLOBAL_SETTINGS_FILE"
load_config
[ "$HTTP_VERSION" = http1.1 ] && [ -z "$CLIENT_IP_HEADER" ] || fail_test 'Legacy conversion changed explicit values'
[ "${GLOBAL_SETTINGS_EXTENSION_VALUES[0]}" = a,b ] || fail_test 'Legacy extension was dropped'
cmp -s "$WORK/legacy.csv" "$WORK/legacy.before" || fail_test 'Converter changed input'
if (GLOBAL_SETTINGS_FILE="$WORK/legacy.csv"; load_config) >/dev/null 2>&1; then fail_test 'Ordinary read accepted legacy globals'; fi
(GLOBAL_SETTINGS_FILE="$WORK/legacy.csv"; DOMAIN_CONFIG_LEGACY_RECOVERY=true; load_config) || fail_test 'Legacy recovery read rejected'

# Backend identifiers are named fields; commas/quotes in option values survive
# reordered headers, normal getter calls, and canonical replacement writes.
printf 'docker_options,domain\n' >"$BACKEND_DOCKER_OPTS_FILE"
csv_join_row '--label "name=a,b"' example.com >>"$BACKEND_DOCKER_OPTS_FILE"
[ "$(get_backend_docker_opts backend:example.com)" = '--label "name=a,b"' ] || fail_test 'Reordered Docker options failed'
set_backend_docker_opts backend:other.example.com '--entrypoint ""'
[ "$(get_backend_docker_opts other.example.com)" = '--entrypoint ""' ] || fail_test 'Empty Docker argument boundary lost'
grep -qx 'domain,docker_options' "$BACKEND_DOCKER_OPTS_FILE" || fail_test 'Docker options header not canonical'
! grep -q '^backend:' "$BACKEND_DOCKER_OPTS_FILE" || fail_test 'Generic backend key remained on disk'
set_backend_docker_opts example.com ''
[ -z "$(get_backend_docker_opts example.com)" ] || fail_test 'Docker options clear failed'
printf 'key,docker_options\nbackend:example.com,--privileged\n' >"$WORK/legacy-options.csv"
_backend_docker_opts_convert_legacy "$WORK/legacy-options.csv" "$BACKEND_DOCKER_OPTS_FILE"
[ "$(get_backend_docker_opts example.com)" = --privileged ] || fail_test 'Legacy Docker option conversion failed'
cp "$BACKEND_DOCKER_OPTS_FILE" "$WORK/options.before"
csv_join_row example.com '--cpus 1' >>"$BACKEND_DOCKER_OPTS_FILE"
cp "$BACKEND_DOCKER_OPTS_FILE" "$WORK/options.invalid"
if set_backend_docker_opts other.example.com '--cpus 2' 2>/dev/null; then fail_test 'Duplicate backend options accepted'; fi
cmp -s "$BACKEND_DOCKER_OPTS_FILE" "$WORK/options.invalid" || fail_test 'Rejected option mutation changed state'

# Shared headers and listener TLS overrides keep their entity-table schemas.
# Header order is interpreted in memory for getters, rendering, CLI/menu views,
# and explicit update/remove operations; read operations preserve source bytes.
source "$ROOT_DIR/lib/headers/common.sh"
source "$ROOT_DIR/lib/headers/list_headers.sh"
source "$ROOT_DIR/lib/headers/_build_header_files.sh"
source "$ROOT_DIR/lib/tls/common.sh"
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"
source "$ROOT_DIR/lib/cli/prompt_args_handlers_defaults.sh"
source "$ROOT_DIR/lib/nginx/status.sh"
CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
NGINX_HTTP_CONF_DIR="$CONFIG_DIR/nginx_conf/conf.d"
mkdir -p "$NGINX_HTTP_CONF_DIR"
printf 'header_value,header_name,header_type\n' >"$CUSTOM_HEADERS_FILE"
csv_join_row 'one,"two"' X-Example response >>"$CUSTOM_HEADERS_FILE"
csv_join_row '' X-Empty request >>"$CUSTOM_HEADERS_FILE"
printf 'tls_protocols,listen_port\nTLSv1.2 TLSv1.3,443\n' >"$PORT_TLS_PROTOCOLS_FILE"
printf 'tls_ciphers,listen_port\nHIGH,443\n' >"$PORT_TLS_CIPHERS_FILE"
cp "$CUSTOM_HEADERS_FILE" "$WORK/headers.before"
cp "$PORT_TLS_PROTOCOLS_FILE" "$WORK/protocols.before"
cp "$PORT_TLS_CIPHERS_FILE" "$WORK/ciphers.before"
[ "$(get_global_header_value X-Example response)" = 'one,"two"' ] || fail_test 'Reordered global header getter failed'
[ -z "$(get_global_header_value X-Empty request)" ] || fail_test 'Blank shared header was lost'
[ "$(get_port_tls_protocols 443)" = 'TLSv1.2 TLSv1.3' ] || fail_test 'Reordered TLS protocols failed'
[ "$(get_port_tls_ciphers 443)" = HIGH ] || fail_test 'Reordered TLS ciphers failed'
_validate_port_tls_file_for_render "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" protocols
_validate_port_tls_file_for_render "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" ciphers
_build_header_files
grep -Fq 'proxy_set_header X-Empty "";' "$NGINX_HTTP_CONF_DIR/custom_headers.conf" || fail_test 'Blank header did not reach renderer'
list_headers >"$WORK/header-list"
grep -Fq 'response X-Example' "$WORK/header-list" || fail_test 'Header listing ignored reordered fields'
[ "$(__arg_choices_custom_header_names response)" = X-Example ] || fail_test 'Interactive header choice failed'
[ "$(__arg_choices_csv_col_values "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" 2 0)" = 443 ] || fail_test 'Interactive TLS choice failed'
PROMPT_ARGS_CONTEXT=(response X-Example)
[ "$(prompt_args_compute_default update-header value '')" = 'one,"two"' ] || fail_test 'Interactive header default failed'
_status_print_global_headers >"$WORK/header-status"
grep -Fq X-Example "$WORK/header-status" || fail_test 'Status omitted reordered headers'
for pair in headers:CUSTOM_HEADERS_FILE protocols:PORT_TLS_PROTOCOLS_FILE ciphers:PORT_TLS_CIPHERS_FILE; do
  field="${pair#*:}"
  cmp -s "${!field}" "$WORK/${pair%%:*}.before" || fail_test 'Read operation rewrote shared source'
done
state_csv_upsert_row_by_keys "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER" 3 2 response X-Example -- response X-Example changed
[ "$(get_global_header_value X-Example response)" = changed ] || fail_test 'Header update lost its logical key'
state_csv_delete_by_keys "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER" 3 2 response X-Example
[ "$(__arg_choices_custom_header_names request)" = X-Empty ] || fail_test 'Header removal lost another row'
state_csv_upsert_two_col_value "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" 443 TLSv1.3
[ "$(get_port_tls_protocols 443)" = TLSv1.3 ] || fail_test 'TLS protocol update failed'
state_csv_delete_two_col_key "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" 443
[ "$(get_port_tls_ciphers 443)" = "$TLS_CIPHERS" ] || fail_test 'TLS cipher removal failed'

# Exercise real generated CSV publication; runtime/settings resolvers supply
# deterministic values without creating or inspecting Docker resources.
config_reset_defaults
TLS_CIPHERS=HIGH
function domain_config_active() { return 0; }
function domain_config_root() { printf '%s\n' "$DOMAINS_DIR"; }
function domain_config_list() { printf 'example.com\n'; }
function domain_config_get() { case "$3" in role) printf 'backend\n' ;; *) printf '\n' ;; esac; }
function _domain_config_has_row() { [ "$2:$3" = 0:client_ip_header ]; }
function get_backend_http_version() { printf 'http2\n'; }
function get_backend_client_ip_header() { printf '\n'; }
function get_backend_proxy_ip_header() { printf 'X-Real-IP\n'; }
function get_backend_acl_policy() { printf 'deny\n'; }
function get_backend_acl_status() { printf '403\n'; }
function get_backend_security_rule_status() { printf '404\n'; }
function _domain_csv_read() { "$2" "$1" 2 443 80 https example.com default; }
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"; NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"; SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"; PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
printf 'listen_port,tls_protocols\n443,TLSv1.2 TLSv1.3\n' >"$PORT_TLS_PROTOCOLS_FILE"
printf 'listen_port,tls_ciphers\n' >"$PORT_TLS_CIPHERS_FILE"
_domain_config_publish_generated
effective="$DOMAINS_DIR/example.com/generated/effective_settings.csv"
{ IFS= read -r header; IFS= read -r record; } <"$effective"
csv_parse_line "$header"; report_headers=("${CSV_FIELDS[@]}")
csv_parse_line "$record"
[ "$CSV_FIELD_COUNT" = 26 ] && [ "${#report_headers[@]}" = 26 ] || fail_test 'Effective singleton shape incorrect'
[ "${report_headers[2]}" = client_ip_header ] && [ -z "${CSV_FIELDS[2]}" ] &&
  [ "${CSV_FIELDS[3]}" = example.com ] || fail_test 'Effective blank/provenance changed'
listeners="$DOMAINS_DIR/example.com/generated/effective_listeners.csv"
grep -qx 'listen_port,protocol,tls_protocols,tls_protocols_source,tls_ciphers,tls_ciphers_source' "$listeners" || fail_test 'Listener header incorrect'
grep -qx '443,https,TLSv1.2 TLSv1.3,listener:443,HIGH,global' "$listeners" || fail_test 'Listener values/provenance changed'
printf '[PASS] shared CSV records, legacy conversion, and generated settings\n'
