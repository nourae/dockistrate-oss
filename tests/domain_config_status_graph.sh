#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
for module in backends nginx nginx_directives ports certs global_settings http_version tls mtls headers security_rules domain_config; do
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_status.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"; CERTS_DIR="$STATE_DIR/certs"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR"
state_csv_ensure_all_state_files
printf '5\n' >"$CONFIG_DIR/state_schema_version"
SKIP_DOCKER_CHECKS=true

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function docker() { fail_test 'status attempted a Docker operation'; }
function domain_config_compile() { fail_test 'status compiled or rendered the configuration'; }
function update_nginx_config() { fail_test 'status rendered live configuration'; }
function new_backend() {
  domain_config_write_template "$1" backend "$DOMAINS_DIR/$1/config"
  _domain_csv_set "$DOMAINS_DIR/$1/config/backend.csv" image nginx:alpine
}
function expect_status() {
  local actual=""
  actual="$(domain_config_status "$1")"
  [ "$actual" = "$2" ] || fail_test "$1: expected '$2', found '$actual'"
}

new_backend example.com
source_dir="$DOMAINS_DIR/example.com/config"
csv_join_row 18180 8080 http '' '' no off '' off auto >>"$source_dir/ports.csv"
_domain_config_copy_inputs "$source_dir" "$DOMAINS_DIR/example.com/runtime/applied"
printf 'domain\nexample.com\n' >"$CONFIG_DIR/domain_inventory.csv"
state_backend_ports_row_backend example.com 192.0.2.1:8080 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"

# Unchanged applied domains keep the cheap path even if other drafts are bad.
mkdir -p "$DOMAINS_DIR/incomplete.example.com/config"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\n' >"$DOMAINS_DIR/incomplete.example.com/config/settings.csv"
(
  function _domain_config_status_draft_valid() { fail_test 'unchanged status validated a whole graph'; }
  expect_status example.com applied
)

domain_config_write_template alias.example.com alias "$DOMAINS_DIR/alias.example.com/config"
_domain_csv_set "$DOMAINS_DIR/alias.example.com/config/domain.csv" target missing.example.com
expect_status alias.example.com 'invalid draft'

printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,8080,https,missing.example.com,certificate,no,off,,off,auto\n' >"$source_dir/ports.csv"
expect_status example.com 'invalid draft'
cp "$DOMAINS_DIR/example.com/runtime/applied/ports.csv" "$source_dir/ports.csv"
csv_join_row api 18181 /api prefix 100 '' none '' >>"$source_dir/paths.csv"
expect_status example.com 'invalid draft'
sed_in_place 's/api,18181,/api,18180,/' "$source_dir/paths.csv"
expect_status example.com 'pending changes'

# New and pending domains use every other domain's applied snapshot. Neither
# incomplete drafts nor an unrelated missing-target alias may poison status.
new_backend other.example.com
csv_join_row 18181 8080 http '' '' no off '' off auto >>"$DOMAINS_DIR/other.example.com/config/ports.csv"
expect_status other.example.com draft
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,8080,tcp,,,no,off,,off,auto\n' >"$DOMAINS_DIR/other.example.com/config/ports.csv"
expect_status other.example.com 'invalid draft'
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,8080,http,,,no,off,,off,auto\n' >"$DOMAINS_DIR/other.example.com/config/ports.csv"
expect_status other.example.com draft

# Checking a pending source must not publish it or alter the active listener.
[ "$(wc -l <"$DOMAINS_DIR/example.com/runtime/applied/paths.csv" | tr -d ' ')" = 1 ] || fail_test 'status published a pending path'
grep -Fq '18180,8080,http' "$DOMAINS_DIR/example.com/runtime/applied/ports.csv" || fail_test 'status modified an applied listener'
printf '[PASS] domain status graph validity and draft isolation\n'
