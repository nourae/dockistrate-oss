#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backends.sh"
source "$ROOT_DIR/lib/security_rules.sh"
source "$ROOT_DIR/lib/domain_config.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/domain-adapter-regressions.XXXXXXXX")"
trap 'rm -rf "$test_root"' EXIT
STATE_DIR="$test_root/state"; DOMAINS_DIR="$STATE_DIR/domains"; CERTS_DIR="$STATE_DIR/certs"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$DOMAINS_DIR/example.com/runtime/applied"
state_csv_ensure_all_state_files
applied="$DOMAINS_DIR/example.com/runtime/applied"

function fail_adapter() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function legacy_rule() {
  local -a fields=(1 example.com single 403 1 path - equals "$1")
  while [ "${#fields[@]}" -lt 45 ]; do fields+=(""); done
  fields+=(- auto require)
  csv_join_row "${fields[@]}"
}
function current_rules() {
  local value=""
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$SECURITY_RULES_FILE"
  for value in "$@"; do legacy_rule "$value" >>"$SECURITY_RULES_FILE"; done
  _domain_config_export_identity_prepare rule
}

# Physical CSV order differs from explicit global order. Editing A to equal B
# must preserve both IDs, including when A previously duplicated another rule.
printf 'rule_id,order,enabled,action,mode,status_code,reason,source_location\nB,20,1,require,single,403,-,auto\nA,10,1,require,single,403,-,auto\nC,30,1,require,single,403,-,auto\n' >"$applied/security_rules.csv"
printf 'rule_id,condition_order,selector,name,operator,value\nA,1,path,-,equals,/a\nB,1,path,-,equals,/b\nC,1,path,-,equals,/a\n' >"$applied/security_conditions.csv"
current_rules /b /b /a
[ "${_dc_export_ids_by_order[*]}" = 'A B C' ] || fail_adapter 'editing an identical rule reassigned IDs'
[ "${_dc_export_orders_by_order[*]}" = '10 20 30' ] || fail_adapter 'editing an identical rule changed order'
current_rules /a /a /a
[ "${_dc_export_ids_by_order[*]}" = 'A B C' ] || fail_adapter 'editing B to equal A/C reassigned IDs'
current_rules /b /a /a
[ "${_dc_export_ids_by_order[*]}" = 'B A C' ] || fail_adapter 'moving a rule failed to retain IDs'
current_rules /new /a /b /a
[ "${_dc_export_ids_by_order[*]}" = 'rule-1 A B C' ] || fail_adapter 'insertion reassigned existing IDs'
[ "${_dc_export_orders_by_order[*]}" = '10 20 30 31' ] || fail_adapter 'insertion changed global sequence'

# Explicit CLI selectors disambiguate deletion/movement of identical contents.
printf 'rule_id,order,enabled,action,mode,status_code,reason,source_location\nA,10,1,require,single,403,-,auto\nB,20,1,require,single,403,-,auto\n' >"$applied/security_rules.csv"
printf 'rule_id,condition_order,selector,name,operator,value\nA,1,path,-,equals,/a\nB,1,path,-,equals,/a\n' >"$applied/security_conditions.csv"
DOMAIN_CONFIG_MUTATION_COMMAND=remove-security-rule DOMAIN_CONFIG_IDENTITY_ARG1=1 DOMAIN_CONFIG_IDENTITY_ARG2=''
current_rules /a
[ "${_dc_export_ids_by_order[*]}" = B ] || fail_adapter 'removing first identical rule kept the removed ID'
DOMAIN_CONFIG_MUTATION_COMMAND=move-security-rule DOMAIN_CONFIG_IDENTITY_ARG1=1 DOMAIN_CONFIG_IDENTITY_ARG2=2
current_rules /a /a
[ "${_dc_export_ids_by_order[*]}" = 'B A' ] || fail_adapter 'moving identical rules did not move their IDs'
DOMAIN_CONFIG_IDENTITY_ARG1=2 DOMAIN_CONFIG_IDENTITY_ARG2=1
current_rules /a /a
[ "${_dc_export_ids_by_order[*]}" = 'B A' ] || fail_adapter 'reverse move of identical rules lost their IDs'
DOMAIN_CONFIG_MUTATION_COMMAND=duplicate-security-rule DOMAIN_CONFIG_IDENTITY_ARG1=1
current_rules /a /a /a
[ "${_dc_export_ids_by_order[*]}" = 'A B rule-3' ] || fail_adapter 'duplication changed existing IDs'
printf 'rule_id,order,enabled,scope,action,ip_value,status_code\nA,10,1,l7,deny,192.0.2.1,403\nB,20,1,l7,deny,192.0.2.1,403\n' >"$applied/acl.csv"
printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_FILE"
csv_join_row 1 example.com l7 deny 192.0.2.1 403 >>"$SECURITY_IP_RULES_FILE"
DOMAIN_CONFIG_MUTATION_COMMAND=remove-acl DOMAIN_CONFIG_IDENTITY_ARG1=1
_domain_config_export_identity_prepare acl
[ "${_dc_export_ids_by_order[*]}" = B ] || fail_adapter 'removing an identical ACL row lost the retained ID'
csv_join_row 1 example.com l7 deny 192.0.2.1 403 >>"$SECURITY_IP_RULES_FILE"
DOMAIN_CONFIG_MUTATION_COMMAND=move-acl-rule DOMAIN_CONFIG_IDENTITY_ARG1=1 DOMAIN_CONFIG_IDENTITY_ARG2=2
_domain_config_export_identity_prepare acl
[ "${_dc_export_ids_by_order[*]}" = 'B A' ] || fail_adapter 'moving identical ACL rows lost their IDs'
printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_FILE"

# Port/path edits preserve explicit path IDs while companion options move.
printf 'path_id,listen_port,path_prefix,match,priority,target,rewrite,header_set\ncustom-path,80,/api,prefix,100,,none,\n' >"$applied/paths.csv"
_dc_domain=example.com _dc_path_count=1
DOMAIN_CONFIG_MUTATION_COMMAND=update-port _UPM_PATH_REWRITE_DOMAIN=example.com _UPM_PATH_REWRITE_OLD_PORT=80 _UPM_PATH_REWRITE_NEW_PORT=8080
_domain_config_export_path_identity 8080 /api
[ "$_dc_export_path_id" = custom-path ] || fail_adapter 'port retarget changed the path ID'
DOMAIN_CONFIG_MUTATION_COMMAND=update-path-option _UPO_REWRITE_APPLIED=yes _UPO_REWRITE_DOMAIN=example.com
_UPO_REWRITE_OLD_PORT=80 _UPO_REWRITE_OLD_PATH=/api _UPO_REWRITE_NEW_PORT=8081 _UPO_REWRITE_NEW_PATH=/v2
_domain_config_export_path_identity 8081 /v2
[ "$_dc_export_path_id" = custom-path ] || fail_adapter 'path rename/retarget changed the path ID'
unset DOMAIN_CONFIG_MUTATION_COMMAND DOMAIN_CONFIG_IDENTITY_ARG1 DOMAIN_CONFIG_IDENTITY_ARG2

# Appending at the largest accepted order must remain possible. Reindex only
# this exhausted case; retain sparse order numbers when no allocation occurs.
printf 'rule_id,order,enabled,action,mode,status_code,reason,source_location\nA,999999999,1,require,single,403,-,auto\n' >"$applied/security_rules.csv"
printf 'rule_id,condition_order,selector,name,operator,value\nA,1,path,-,equals,/a\n' >"$applied/security_conditions.csv"
current_rules /a
[ "${_dc_export_orders_by_order[*]}" = 999999999 ] || fail_adapter 'unchanged maximum order was needlessly renumbered'
current_rules /a /new
[ "${_dc_export_ids_by_order[*]}" = 'A rule-2' ] && [ "${_dc_export_orders_by_order[*]}" = '1 2' ] || fail_adapter 'order allocation overflowed the source schema'

# Byte-identical moves leave the aggregate fingerprint unchanged. Exercise the
# real sync/export/validation path to ensure it still publishes the moved IDs.
(
  for module in logging nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules; do source "$ROOT_DIR/lib/$module.sh"; done
  STATE_DIR="$test_root/sync-state"; DOMAINS_DIR="$STATE_DIR/domains"; CERTS_DIR="$STATE_DIR/certs"; TMP_DIR="$STATE_DIR/tmp"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$TMP_DIR"
  config_reset_defaults
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  state_csv_ensure_all_state_files
  printf '5\n' >"$CONFIG_DIR/state_schema_version"
  SKIP_DOCKER_CHECKS=true
  source_config="$DOMAINS_DIR/example.com/config"
  domain_config_write_template example.com backend "$source_config"
  _domain_csv_set "$source_config/backend.csv" image nginx:alpine
  printf 'rule_id,order,enabled,action,mode,status_code,reason,source_location\nA,10,1,require,single,403,-,auto\nB,20,1,require,single,403,-,auto\n' >"$source_config/security_rules.csv"
  printf 'rule_id,condition_order,selector,name,operator,value\nA,1,path,-,equals,/a\nB,1,path,-,equals,/a\n' >"$source_config/security_conditions.csv"
  _domain_config_copy_inputs "$source_config" "$DOMAINS_DIR/example.com/runtime/applied"
  state_backend_ports_row_backend example.com 192.0.2.1:8080 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
  legacy_rule /a >>"$SECURITY_RULES_FILE"
  legacy_rule /a >>"$SECURITY_RULES_FILE"
  sync_work="$test_root/sync"
  _domain_config_command_snapshot "$sync_work"
  function _domain_config_source_publish() { _domain_config_copy_inputs "$2" "$DOMAINS_DIR/$1/config"; }
  DOMAIN_CONFIG_MUTATION_COMMAND=move-security-rule DOMAIN_CONFIG_IDENTITY_ARG1=1 DOMAIN_CONFIG_IDENTITY_ARG2=2
  _domain_config_sync_command "$sync_work"
  grep -Fxq 'B,10,1,require,single,403,-,auto' "$source_config/security_rules.csv" || fail_adapter 'sync skipped an identical-content rule move'
  grep -Fxq 'A,20,1,require,single,403,-,auto' "$DOMAINS_DIR/example.com/runtime/applied/security_rules.csv" || fail_adapter 'sync did not accept moved stable identities'
)

# Alias-only declarations must correspond to settings the renderer consumes.
(
  for module in ports nginx_directives headers security_rules; do source "$ROOT_DIR/lib/$module.sh"; done
  alias_config="$test_root/alias-config"
  domain_config_write_template alias.example.com alias "$alias_config"
  _domain_csv_set "$alias_config/domain.csv" target example.com
  csv_join_row response X-Alias 'supported, "value"' >>"$alias_config/headers.csv"
  _domain_csv_set "$alias_config/settings.csv" acl_policy allow
  _domain_csv_set "$alias_config/settings.csv" acl_status 403
  _domain_csv_set "$alias_config/settings.csv" security_rule_status 429
  csv_join_row alias-acl 1 1 l7 deny 192.0.2.1 403 >>"$alias_config/acl.csv"
  csv_join_row alias-rule 1 1 require single - - auto >>"$alias_config/security_rules.csv"
  csv_join_row alias-rule 1 path - equals /private >>"$alias_config/security_conditions.csv"
  csv_join_row owned selfsigned 443 '' '' >>"$alias_config/certificates.csv"
  domain_config_validate_source alias.example.com "$alias_config" || fail_adapter 'supported alias declarations were rejected'
  function reject_alias_declaration() {
    if domain_config_validate_source alias.example.com "$alias_config" >"$test_root/alias-error" 2>&1; then fail_adapter 'ignored alias declaration was accepted'; fi
    grep -Fq 'configure the target backend or use a dedicated host' "$test_root/alias-error" || fail_adapter 'alias validation omitted actionable guidance'
  }
  for key in http_version client_ip_header proxy_ip_header; do
    value=off; [ "$key" != http_version ] || value=http2
    _domain_csv_set "$alias_config/settings.csv" "$key" "$value"
    reject_alias_declaration
    _domain_csv_set "$alias_config/settings.csv" "$key" ''
  done
  csv_join_row p1 80 /api prefix 100 '' none '' >>"$alias_config/paths.csv"
  reject_alias_declaration
  _domain_csv_write_header "$alias_config/paths.csv"
  _domain_csv_set "$alias_config/path_options.csv" p1 websocket yes
  reject_alias_declaration
  _domain_csv_write_header "$alias_config/path_options.csv"
  csv_join_row backend '' '' raw client_max_body_size 2m >>"$alias_config/nginx_directives.csv"
  reject_alias_declaration
  _domain_csv_write_header "$alias_config/nginx_directives.csv"
  _domain_csv_set "$alias_config/mtls.csv" enabled no
  reject_alias_declaration
  _domain_csv_write_header "$alias_config/mtls.csv"
  domain_config_validate_source alias.example.com "$alias_config" || fail_adapter 'removing ignored overrides did not restore a valid alias'
)

# A malformed/domainless row cannot vanish before export chooses its owners.
# Snapshot the whole private config tree to prove preflight remains read-only.
rm -rf "$DOMAINS_DIR"
printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$SECURITY_RULES_FILE"
function state_digest() {
  (cd "$CONFIG_DIR"; for file in *.csv; do printf '%s\n' "$file"; cksum <"$file"; done)
}
function reject_migration() {
  local before="" after=""
  before="$(state_digest)"
  if _domain_config_migration_build "$test_root/rejected-candidate" >"$test_root/error" 2>&1; then fail_adapter 'migration discarded malformed legacy state'; fi
  after="$(state_digest)"
  [ "$before" = "$after" ] || fail_adapter 'migration preflight modified legacy state'
  [ ! -d "$test_root/rejected-candidate/candidate" ] ||
    [ -z "$(find "$test_root/rejected-candidate/candidate" -type f -print)" ] || fail_adapter 'migration exported before checking every legacy row'
}
function docker() { fail_adapter 'invalid migration preflight attempted a Docker operation'; }
printf 'backend\n' >>"$BACKEND_PORTS_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 192.0.2.1:8080 testnet | sed 's/^backend,/bogus,/' >>"$BACKEND_PORTS_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
csv_join_row bogus example.com target.example.com >>"$BACKEND_ALIASES_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"
csv_join_row bogus '' '' '' raw proxy_timeout 60s >>"$NGINX_DIRECTIVES_FILE"
reject_migration
printf '%s\n' "$STATE_NGINX_DIRECTIVES_HEADER" >"$NGINX_DIRECTIVES_FILE"
csv_join_row '' response X-Message 'quoted, "value"' >>"$BACKEND_HEADERS_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER" >"$BACKEND_HEADERS_FILE"
legacy_rule /blocked | sed 's/example.com//' >>"$SECURITY_RULES_FILE"
reject_migration
printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$SECURITY_RULES_FILE"
printf 'incorrect_header\n' >"$BACKEND_MTLS_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" >"$BACKEND_MTLS_FILE"

# Owner records must remain unambiguous before export folds scalar backend and
# host metadata into one domain.csv. Shared listener/certificate owners are fine.
state_backend_ports_row_backend example.com 192.0.2.1:8080 testnet >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 192.0.2.2:9090 othernet >>"$BACKEND_PORTS_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
csv_join_row alias example.com first.example.com >>"$BACKEND_ALIASES_FILE"
csv_join_row dedicated example.com second.example.com >>"$BACKEND_ALIASES_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"
state_backend_ports_row_backend example.com 192.0.2.1:8080 testnet >>"$BACKEND_PORTS_FILE"
csv_join_row alias example.com target.example.com >>"$BACKEND_ALIASES_FILE"
reject_migration
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"
state_backend_ports_row_backend other.example.com 192.0.2.2:8080 testnet >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_port example.com 80 8080 http none no off '' >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_port other.example.com 80 8080 http none no off '' >>"$BACKEND_PORTS_FILE"
csv_join_row alias alias.example.com example.com >>"$BACKEND_ALIASES_FILE"
mkdir -p "$CERTS_DIR/selfsigned/live/example.com_443"
[ "$(_domain_config_legacy_domains)" = $'alias.example.com\nexample.com\nother.example.com' ] || fail_adapter 'valid shared listener or certificate owner was rejected'
rmdir "$CERTS_DIR/selfsigned/live/example.com_443"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"

# Global directives legitimately have empty owner/port/path columns. Empty
# optional values in shared headers/settings must also remain untouched.
csv_join_row global '' '' '' managed client_max_body_size 2m >>"$NGINX_DIRECTIVES_FILE"
csv_join_row stream-global '' '' '' raw proxy_timeout 60s >>"$NGINX_DIRECTIVES_FILE"
csv_join_row response X-Empty '' >>"$CUSTOM_HEADERS_FILE"
[ -z "$(_domain_config_legacy_domains)" ] || fail_adapter 'global configuration was mistaken for a domain owner'
printf '[PASS] domain adapter stable identities and migration preflight\n'
