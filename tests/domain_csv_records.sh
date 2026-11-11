#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
for module in logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-csv-records.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; CERTS_DIR="$STATE_DIR/certs"; TMP_DIR="$STATE_DIR/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
config_reset_defaults
SKIP_DOCKER_CHECKS=true INTERACTIVE=false
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_csv_ensure_all_state_files

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function reject_test() {
  if "$@" >"$TEST_WORK/rejected" 2>&1; then fail_test "Unexpected success: $*"; fi
}
function assert_header() {
  local line=""
  IFS= read -r line <"$1"
  [ "$line" = "$2" ] || fail_test "Wrong header in $1: $line"
}

config="$TEST_WORK/example.com/config"
domain_config_write_template example.com backend "$config"
_domain_csv_set "$config/backend.csv" image nginx:alpine
assert_header "$config/domain.csv" schema_version,role,target
assert_header "$config/backend.csv" image,container_port,network,state
assert_header "$config/settings.csv" http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status
assert_header "$config/inheritance.csv" mtls,acl,security_rules,headers,paths
assert_header "$config/mtls.csv" enabled,directory
assert_header "$config/ports.csv" listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc
assert_header "$config/path_options.csv" path_id,websocket,redirect_enabled,redirect_code,reason,source_location
assert_header "$config/certificates.csv" certificate_id,provider,port_suffix,source_fullchain,source_privkey
[ ! -e "$config/port_options.csv" ] && [ ! -e "$config/certificate_options.csv" ] || fail_test 'Template retained split entity options'
[ "$(wc -l <"$config/backend.csv" | tr -d ' ')" = 2 ] || fail_test 'Backend must be one record'
[ "$(domain_config_get "$config" domain.csv schema_version)" = 5 ] || fail_test 'Template schema is stale'
domain_config_validate_directory example.com "$config"
base="$(domain_config_canonicalize "$config")"

# Every file has a canonical named-field header. A reader maps a quoted,
# reordered header with CRLF to the same semantic values without rewriting it.
printf '"state",network,"image",container_port\r\nrunning,%s,"nginx:alpine",8080\r\n' "$DEFAULT_NETWORK" >"$config/backend.csv"
cp "$config/backend.csv" "$TEST_WORK/reordered-before"
domain_config_validate_directory example.com "$config"
[ "$(domain_config_canonicalize "$config")" = "$base" ] || fail_test 'Reordered CRLF backend changed semantics'
cmp -s "$TEST_WORK/reordered-before" "$config/backend.csv" || fail_test 'Reading rewrote the source'
_domain_csv_set "$config/backend.csv" state stopped
assert_header "$config/backend.csv" image,container_port,network,state
[ "$(domain_config_get "$config" backend.csv state)" = stopped ] || fail_test 'Setter failed after header reordering'
_domain_csv_set "$config/backend.csv" state running

# A header-only optional record, an all-default row, and an omitted file are
# equivalent; meaningful empty values in entity rows must not disappear.
cp "$config/settings.csv" "$TEST_WORK/settings-header"
printf '%s\n' 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status' ',,,,,' >"$config/settings.csv"
[ "$(domain_config_canonicalize "$config")" = "$base" ] || fail_test 'Blank optional settings did not inherit'
_domain_csv_set "$config/settings.csv" client_ip_header off
[ "$(domain_config_canonicalize "$config")" != "$base" ] || fail_test 'Explicit header off became inheritance'
_domain_csv_set "$config/settings.csv" client_ip_header ''
[ "$(domain_config_canonicalize "$config")" = "$base" ] || fail_test 'Cleared override did not inherit'
rm "$config/settings.csv"
[ "$(domain_config_canonicalize "$config")" = "$base" ] || fail_test 'Absent optional settings changed semantics'
cp "$TEST_WORK/settings-header" "$config/settings.csv"
csv_join_row response X-Empty '' >>"$config/headers.csv"
[ "$(domain_config_canonicalize "$config")" != "$base" ] || fail_test 'Empty header override disappeared'
_domain_csv_write_header "$config/headers.csv"
csv_join_row 1 '' >>"$config/docker_options.csv"
[ "$(domain_config_canonicalize "$config")" != "$base" ] || fail_test 'Empty Docker argument disappeared'
_domain_csv_write_header "$config/docker_options.csv"

# CSV syntax and cardinality failures are rejected before interpretation.
for row in \
  'image,image,network,state|nginx:alpine,8080,dockistrate-net,running' \
  'image,container_port,network,unknown|nginx:alpine,8080,dockistrate-net,running' \
  'image,container_port,state|nginx:alpine,8080,running' \
  'image,container_port,network,state|nginx:alpine,8080,running' \
  'image,container_port,network,state|"unclosed,8080,dockistrate-net,running'; do
  printf '%s\n%s\n' "${row%%|*}" "${row#*|}" >"$config/backend.csv"
  reject_test domain_config_validate_directory example.com "$config"
done
printf 'image,container_port,network,state\nnginx:alpine,8080,,running\nnginx:alpine,8080,,running\n' >"$config/backend.csv"
reject_test domain_config_validate_directory example.com "$config"
printf 'image,container_port,network,state\n' >"$config/backend.csv"
reject_test domain_config_validate_directory example.com "$config"
_domain_csv_set "$config/backend.csv" image nginx:alpine
_domain_csv_set "$config/backend.csv" container_port 8080
csv_join_row 80 8080 http '' '' no off '' off auto >>"$config/ports.csv"
_domain_csv_set "$config/ports.csv" 80 http websocket yes
_domain_csv_set "$config/ports.csv" 80 http redirect_enabled on
[ "$(wc -l <"$config/ports.csv" | tr -d ' ')" = 2 ] || fail_test 'Listener options were split into separate records'
domain_config_validate_directory example.com "$config"
sed -n '2p' "$config/ports.csv" >>"$config/ports.csv"
reject_test domain_config_validate_directory example.com "$config"

# A legacy explicit blank IP override becomes off. The converter rejects
# ambiguous duplicate keys, while original inputs stay byte-for-byte intact.
legacy="$TEST_WORK/legacy"; mkdir -p "$legacy"
printf 'key,value\nschema_version,2\nrole,backend\n' >"$legacy/domain.csv"
printf 'key,value\nimage,nginx:alpine\ncontainer_port,8080\n' >"$legacy/backend.csv"
printf 'key,value\nclient_ip_header,\nproxy_ip_header,off\n' >"$legacy/settings.csv"
cp "$legacy/settings.csv" "$TEST_WORK/legacy-before"
DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3 _domain_csv_convert_v2_directory "$legacy" "$TEST_WORK/converted"
[ "$(domain_config_get "$TEST_WORK/converted" settings.csv client_ip_header)" = off ] || fail_test 'Migration lost old blank override'
[ "$(domain_config_get "$TEST_WORK/converted" domain.csv schema_version)" = 3 ] || fail_test 'Conversion did not update domain schema'
cmp -s "$legacy/settings.csv" "$TEST_WORK/legacy-before" || fail_test 'Conversion changed original input'
printf 'client_ip_header,off\n' >>"$legacy/settings.csv"
DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3 reject_test _domain_csv_convert_v2_directory "$legacy" "$TEST_WORK/rejected-conversion"
# Retrying a rolled-back migration can encounter a draft edited after its
# record-format publication. Preserve current blank semantics in mixed input.
mixed="$TEST_WORK/mixed"; mkdir -p "$mixed"
printf 'key,value\nschema_version,2\nrole,backend\n' >"$mixed/domain.csv"
printf 'image,container_port,network,state\nnginx:alpine,8080,,running\n' >"$mixed/backend.csv"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\n,,,,,\n' >"$mixed/settings.csv"
DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3 _domain_csv_convert_v2_directory "$mixed" "$TEST_WORK/retry"
[ "$(domain_config_get "$TEST_WORK/retry" settings.csv client_ip_header inherited)" = inherited ] || fail_test 'Retry changed current blank into legacy off'
[ "$(domain_config_get "$TEST_WORK/retry" domain.csv schema_version)" = 3 ] || fail_test 'Retry missed legacy portion'
DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3 DOMAIN_CONFIG_LEGACY_RECOVERY=true domain_config_validate_directory example.com "$TEST_WORK/retry"
printf '[PASS] named-field domain CSV contract\n'
