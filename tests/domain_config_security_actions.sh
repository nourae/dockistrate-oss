#!/usr/bin/env bash
# Fixture settings are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
for module in logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-security-actions.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; CERTS_DIR="$STATE_DIR/certs"; TMP_DIR="$STATE_DIR/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
config_reset_defaults
SKIP_DOCKER_CHECKS=true INTERACTIVE=false
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_csv_ensure_all_state_files

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function reject_test() { if "$@" >"$TEST_WORK/rejected" 2>&1; then fail_test "Unexpected success: $*"; fi; }

config="$TEST_WORK/candidate/example.com/config"
domain_config_write_template example.com backend "$config"
_domain_csv_set "$config/backend.csv" image nginx:alpine
[ "$(domain_config_get "$config" domain.csv schema_version)" = 5 ] || fail_test 'Template schema is stale'
[ "$(head -n 1 "$config/security_rules.csv")" = 'rule_id,order,enabled,action,mode,status_code,reason,source_location' ] || fail_test 'Missing action header'
csv_join_row rule-1 4 1 require single 403 'Blocked, "request"' auto >>"$config/security_rules.csv"
csv_join_row rule-1 1 header X-Access equals 'secret,value' >>"$config/security_conditions.csv"
domain_config_validate_source example.com "$config"
canonical="$(domain_config_canonicalize "$config")"
printf 'mode,rule_id,enabled,reason,order,source_location,action,status_code\r\nsingle,rule-1,1,"Blocked, ""request""",4,auto,,403\r\n' >"$config/security_rules.csv"
cp "$config/security_rules.csv" "$TEST_WORK/original"
domain_config_validate_source example.com "$config"
[ "$(domain_config_canonicalize "$config")" = "$canonical" ] || fail_test 'Blank action differs from explicit require'
cmp -s "$config/security_rules.csv" "$TEST_WORK/original" || fail_test 'Reading rewrote the editable source'

_dc_domain=example.com; _dc_config="$config"; _dc_output="$TEST_WORK/compiled"
mkdir -p "$_dc_output"
for action in require block allow; do
  _domain_csv_write_header "$config/security_rules.csv"
  csv_join_row rule-1 4 1 "$action" single 403 'Blocked, "request"' auto >>"$config/security_rules.csv"
  domain_config_validate_source example.com "$config"
  : >"$_dc_output/.domain-security-rows"
  _domain_csv_read "$config/security_rules.csv" _domain_config_compile_rule
  compiled="$(cut -f2- "$_dc_output/.domain-security-rows")"
  csv_parse_line "$compiled"
  [ "$CSV_FIELD_COUNT" = 48 ] && [ "${CSV_FIELDS[47]}" = "$action" ] || fail_test 'Compile lost action'
  [ "${CSV_FIELDS[45]}" = 'Blocked, "request"' ] && [ "${CSV_FIELDS[46]}" = auto ] || fail_test 'Existing aggregate offsets changed'
  [ "${CSV_FIELDS[8]}" = 'secret,value' ] || fail_test 'Condition field boundary changed'
  line="$(_sr_write_db_line_with_action "$action" 1 example.com single 403 1 'Blocked, "request"' auto header X-Access equals 'secret,value')"
  [ "$line" = "$compiled" ] || fail_test 'CLI and CSV writer contracts differ'
  _dc_destination="$TEST_WORK/export-$action"; mkdir -p "$_dc_destination"
  _domain_csv_write_header "$_dc_destination/security_rules.csv"
  _domain_csv_write_header "$_dc_destination/security_conditions.csv"
  _dc_export_ids_by_order=(rule-1); _dc_export_orders_by_order=(4)
  _domain_config_export_rule_row 2 "${CSV_FIELDS[@]}"
  cmp -s "$config/security_rules.csv" "$_dc_destination/security_rules.csv" || fail_test 'Export lost rule identity or action'
done
line="$(_sr_write_db_line 1 example.com single 403 1 header X-Access equals secret)"
csv_parse_line "$line"
[ "$CSV_FIELD_COUNT" = 48 ] && [ "${CSV_FIELDS[47]}" = require ] || fail_test 'Old writer no longer defaults to require'
reject_test _sr_write_db_line_with_action bypass 1 example.com single 403 1 header X-Access equals secret
_domain_csv_write_header "$config/security_rules.csv"
csv_join_row rule-1 4 1 bypass single 403 - auto >>"$config/security_rules.csv"
reject_test domain_config_validate_source example.com "$config"

# Restored schema3/4 snapshots are normalized in memory, while their aggregate
# writer stays at the historical 47-column contract until explicit migration.
for version in 3 4; do
  (
    _domain_config_use_input_schema "$version"
    _domain_csv_write_header "$config/security_rules.csv"
    csv_join_row rule-1 4 1 single 403 'Blocked, "request"' auto >>"$config/security_rules.csv"
    : >"$_dc_output/.domain-security-rows"
    _domain_csv_read "$config/security_rules.csv" _domain_config_compile_rule
    csv_parse_line "$(cut -f2- "$_dc_output/.domain-security-rows")"
    [ "$CSV_FIELD_COUNT" = 47 ] || fail_test 'Historical recovery emitted a current aggregate'
    [ "${CSV_FIELDS[2]}" = single ] && [ "${CSV_FIELDS[45]}" = 'Blocked, "request"' ] || fail_test 'Historical rule was shifted'
    reject_test _sr_write_db_line_with_action block 1 example.com single 403 1 header X-Access equals secret
  )
done
[ "$STATE_SECURITY_RULES_COLS" = 48 ] || fail_test 'Historical scope leaked into current writer'
printf '[PASS] Domain security action model and scoped aggregate codecs\n'
