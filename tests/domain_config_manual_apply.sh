#!/usr/bin/env bash
# Runtime/configuration variables are consumed by sourced production functions.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-manual-apply.XXXXXXXX")"
# Backup publication returns physical paths; use the same root in fault hooks.
test_root="$(cd "$test_root" && pwd -P)"
trap 'rm -rf "$test_root"' EXIT
BASE_DIR="$test_root"
STATE_DIR="$test_root/state"
DOMAINS_DIR="$STATE_DIR/domains"
CERTS_DIR="$STATE_DIR/certs"
BACKUP_DIR="$STATE_DIR/backups"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha256"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
_domain_config_bind_config "$STATE_DIR/config"
config_reset_defaults
SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
ENABLE_AUTO_BACKUPS=true
ENABLE_BACKUP_COMPRESSION=false
BACKUP_RETENTION=0
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$TMP_DIR" "$ERROR_LOG_DIR" "$NGINX_CONFIG_DIR"
printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_csv_ensure_all_state_files
touch "$NGINX_CONFIG_DIR/nginx.conf"

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function log_msg() { :; }
function capture_docker_logs() { :; }
function _backend_runtime_install_signal_traps() { :; }
function _domain_config_ensure_mutation_runtime() { :; }
function domain_config_runtime_preflight() { :; }
function domain_config_provision_certificates() { :; }
function domain_config_reconcile_backends() { :; }
function domain_config_runtime_matches() { return 0; }
function _domain_config_generated_ready() { return 0; }
function get_all_mapped_port_bindings() { printf '80/tcp\n'; }
# Keep real model validation, compilation, publication, transactions, backups,
# and rollback. Rendering/runtime activation are represented by these records.
function domain_config_validate_tree() { _domain_config_validate_source_tree "$1"; }
function update_nginx_config() {
  printf '%s,%s\n' "${DOCKISTRATE_FORCE_NGINX_RECREATE:-false}" "${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-false}" >>"$test_root/proxy-calls"
  cp "$BACKEND_HEADERS_FILE" "$test_root/runtime-headers"
}
function _domain_runtime_restore_proxy() { cp "$test_root/runtime-before" "$test_root/runtime-headers"; }
eval "$(declare -f domain_config_backup_write | sed '1s/domain_config_backup_write/_test_backup_write/')"
function domain_config_backup_write() {
  printf '%s\n' "$1" >>"$test_root/snapshot-calls"
  case "$1" in "$BACKUP_DIR"/*) [ "${FAIL_SNAPSHOT:-false}" != true ] || return 1 ;; esac
  _test_backup_write "$@"
}
function line_count() {
  if [ -f "$1" ]; then wc -l <"$1" | tr -d '[:space:]'; else printf '0\n'; fi
}

candidate="$test_root/candidate"
for domain in example.com other.example.com www.example.com; do
  kind=backend
  [ "$domain" != www.example.com ] || kind=dedicated
  config="$DOMAINS_DIR/$domain/config"
  domain_config_write_template "$domain" "$kind" "$config"
  if [ "$kind" = backend ]; then
    _domain_csv_set "$config/backend.csv" image nginx:alpine
  else
    _domain_csv_set "$config/domain.csv" target example.com
  fi
done
config="$DOMAINS_DIR/example.com/config"
csv_join_row 80 8080 http '' '' no off '' off auto >>"$config/ports.csv"
csv_join_row response X-Revision before >>"$config/headers.csv"
csv_join_row rule-a 10 1 require single '' '' '' >>"$config/security_rules.csv"
csv_join_row rule-b 20 1 require single 403 - auto >>"$config/security_rules.csv"
csv_join_row rule-a 1 method - equals GET >>"$config/security_conditions.csv"
csv_join_row rule-b 1 path - starts_with / >>"$config/security_conditions.csv"
csv_join_row acl-a 1 1 l7 deny 192.0.2.3 403 >>"$config/acl.csv"
for domain in example.com other.example.com www.example.com; do
  _domain_config_copy_inputs "$DOMAINS_DIR/$domain/config" "$DOMAINS_DIR/$domain/runtime/applied"
  _domain_config_copy_inputs "$DOMAINS_DIR/$domain/config" "$candidate/$domain/config"
done
config="$candidate/example.com/config"
applied="$DOMAINS_DIR/example.com/runtime/applied"
function expect_security_change() {
  local actual=""
  actual="$(_domain_config_security_changed "$candidate")" || fail_test "Security comparison failed: $2"
  [ "$actual" = "$1" ] || fail_test "Expected security change=$1: $2; got $actual"
}
expect_security_change false 'identical configuration'

# Quoting, CRLF, table row order, and explicit defaults are presentation only.
printf 'rule_id,order,enabled,action,mode,status_code,reason,source_location\r\n"rule-b",20,1,require,single,403,-,auto\r\n"rule-a",10,1,require,single,-,-,auto\r\n' >"$config/security_rules.csv"
printf 'mtls,acl,security_rules,headers,paths\nyes,yes,yes,yes,yes\n' >"$candidate/www.example.com/config/inheritance.csv"
expect_security_change false 'normalized rule/default/inheritance representation'
cp "$applied/security_rules.csv" "$config/security_rules.csv"
cp "$DOMAINS_DIR/www.example.com/runtime/applied/inheritance.csv" "$candidate/www.example.com/config/inheritance.csv"

# Changing policy action is a security change even when conditions stay equal.
sed_in_place 's/rule-a,10,1,require,/rule-a,10,1,block,/' "$config/security_rules.csv"
expect_security_change true 'rule action changed from require to block'
cp "$applied/security_rules.csv" "$config/security_rules.csv"

for setting in client_ip_header acl_policy acl_status security_rule_status; do
  case "$setting" in client_ip_header) value=off ;; acl_policy) value=deny ;; *) value=451 ;; esac
  _domain_csv_set "$config/settings.csv" "$setting" "$value"
  expect_security_change true "$setting"
  cp "$applied/settings.csv" "$config/settings.csv"
done
for setting in http_version proxy_ip_header; do
  case "$setting" in http_version) value=http2 ;; *) value=off ;; esac
  _domain_csv_set "$config/settings.csv" "$setting" "$value"
  expect_security_change false "$setting uses ordinary reload"
  cp "$applied/settings.csv" "$config/settings.csv"
done
for feature in acl security_rules headers mtls paths; do
  _domain_csv_set "$candidate/www.example.com/config/inheritance.csv" "$feature" no
  case "$feature" in acl | security_rules | headers) expected=true ;; *) expected=false ;; esac
  expect_security_change "$expected" "$feature inheritance"
  cp "$DOMAINS_DIR/www.example.com/runtime/applied/inheritance.csv" "$candidate/www.example.com/config/inheritance.csv"
done
_domain_csv_set "$candidate/www.example.com/config/domain.csv" target other.example.com
expect_security_change true 'retargeted dedicated host'
cp "$DOMAINS_DIR/www.example.com/runtime/applied/domain.csv" "$candidate/www.example.com/config/domain.csv"
_domain_csv_set "$candidate/www.example.com/config/domain.csv" role alias
expect_security_change true 'changed hostname association'
cp "$DOMAINS_DIR/www.example.com/runtime/applied/domain.csv" "$candidate/www.example.com/config/domain.csv"
for filename in security_rules.csv security_conditions.csv acl.csv; do
  _domain_csv_write_header "$config/$filename"
  expect_security_change true "removed $filename rows"
  cp "$applied/$filename" "$config/$filename"
done
csv_join_row response X-Extra value >>"$config/headers.csv"
_domain_csv_set "$config/backend.csv" state stopped
_domain_csv_set "$config/ports.csv" 80 http websocket yes
expect_security_change false 'ordinary headers/backend/listener settings'
for filename in headers.csv backend.csv ports.csv; do cp "$applied/$filename" "$config/$filename"; done

# Unrelated drafts cannot become active policy or disable selected-domain
# comparison. Only --all inspects malformed/unapplied domain folder inventory.
printf 'unfinished,"draft\n' >"$DOMAINS_DIR/other.example.com/config/settings.csv"
mkdir -p "$DOMAINS_DIR/UPPER.Example/config" "$DOMAINS_DIR/incomplete.example.com/config"
printf 'unfinished,"draft\n' >"$DOMAINS_DIR/UPPER.Example/config/domain.csv"
printf 'Notes\n' >"$DOMAINS_DIR/README.txt"
expect_security_change false 'unselected invalid drafts and unrelated root entries'
_domain_config_preview_proxy "$candidate" false '' >"$test_root/preview"
grep -q 'Proxy: unchanged' "$test_root/preview" || fail_test 'Unselected draft changed preview.'
rm -rf "$DOMAINS_DIR/UPPER.Example" "$DOMAINS_DIR/README.txt"

_domain_csv_set "$config/settings.csv" client_ip_header off
_domain_config_preview_proxy "$candidate" true '' >"$test_root/preview"
grep -q 'Proxy: recreate' "$test_root/preview" || fail_test 'Security preview did not recreate.'
cp "$applied/settings.csv" "$config/settings.csv"
_domain_config_preview_proxy "$candidate" true '' >"$test_root/preview"
grep -q 'Proxy: reload' "$test_root/preview" || fail_test 'Ordinary edit preview did not reload.'
printf 'malformed,"rule\n' >"$config/security_rules.csv"
if _domain_config_security_changed "$candidate" >"$test_root/rejected" 2>&1; then fail_test 'Malformed candidate policy was treated as unchanged.'; fi
if _domain_config_preview_proxy "$candidate" true '' >"$test_root/rejected" 2>&1; then fail_test 'Preview swallowed a policy read error.'; fi
cp "$applied/security_rules.csv" "$config/security_rules.csv"
cp "$applied/security_rules.csv" "$test_root/saved-rules.csv"
printf 'malformed,"rule\n' >"$applied/security_rules.csv"
if _domain_config_security_changed "$candidate" >"$test_root/rejected" 2>&1; then fail_test 'Malformed applied policy was treated as unchanged.'; fi
if apply_domain_config example.com >"$test_root/rejected" 2>&1; then fail_test 'Apply swallowed an applied-policy read error.'; fi
[ ! -e "$test_root/proxy-calls" ] && [ ! -e "$test_root/snapshot-calls" ] || fail_test 'A policy read error reached activation or backup.'
cp "$test_root/saved-rules.csv" "$applied/security_rules.csv"

# File-only manual apply must use the finalized applied model in an automatic
# full backup even though no backend/certificate helper requests a backup.
domain_config_compile "$candidate" "$test_root/compiled"
_domain_config_publish_cache "$test_root/compiled"
cp "$BACKEND_HEADERS_FILE" "$test_root/runtime-headers"
cp "$test_root/runtime-headers" "$test_root/runtime-before"
config="$DOMAINS_DIR/example.com/config"
_domain_csv_write_header "$config/headers.csv"
csv_join_row response X-Revision after >>"$config/headers.csv"
apply_domain_config example.com >"$test_root/apply.out" 2>&1 || { cat "$test_root/apply.out" >&2; fail_test 'Headers-only apply failed.'; }
[ "$(cat "$test_root/proxy-calls")" = false,false ] || fail_test 'Ordinary edit forced security recreation.'
[ "$(line_count "$test_root/snapshot-calls")" -eq 2 ] || fail_test 'File-only apply omitted its finalized automatic snapshot.'
snapshot="$(cat "$FULL_BACKUP_FILE")"
cmp -s "$config/headers.csv" "$snapshot/domains/example.com/config/headers.csv" || fail_test 'Backup has stale editable headers.'
cmp -s "$config/headers.csv" "$snapshot/domains/example.com/runtime/applied/headers.csv" || fail_test 'Backup has stale applied headers.'
cmp -s "$BACKEND_HEADERS_FILE" "$snapshot/config/backend_headers.csv" || fail_test 'Backup has stale compiled headers.'
cmp -s "$DOMAINS_DIR/other.example.com/config/settings.csv" "$snapshot/domains/other.example.com/config/settings.csv" || fail_test 'Backup lost an unrelated invalid draft.'
[ -d "$snapshot/domains/incomplete.example.com/config" ] || fail_test 'Backup lost an unrelated incomplete draft.'
before_pointer="$(cat "$FULL_BACKUP_FILE")"
before_checksum="$(cat "$FULL_BACKUP_CHECKSUM_FILE")"
apply_domain_config example.com >"$test_root/unchanged.out" 2>&1 || fail_test 'Unchanged apply failed.'
grep -q 'Configuration and runtime are unchanged' "$test_root/unchanged.out" || fail_test 'Unchanged apply was not a no-op.'
[ "$(line_count "$test_root/proxy-calls")" -eq 1 ] && [ "$(line_count "$test_root/snapshot-calls")" -eq 2 ] || fail_test 'Unchanged apply rendered or backed up again.'
[ "$(cat "$FULL_BACKUP_FILE")" = "$before_pointer" ] && [ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$before_checksum" ] || fail_test 'Unchanged apply changed backup metadata.'

_domain_csv_set "$config/settings.csv" client_ip_header off
apply_domain_config example.com --dry-run >"$test_root/dry-run.out" 2>&1 || fail_test 'Manual security preview failed.'
grep -q 'Proxy: recreate' "$test_root/dry-run.out" || fail_test 'Manual security preview disagrees with activation.'
[ "$(line_count "$test_root/proxy-calls")" -eq 1 ] && [ "$(line_count "$test_root/snapshot-calls")" -eq 2 ] || fail_test 'Preview activated or backed up state.'
apply_domain_config example.com >"$test_root/security.out" 2>&1 || { cat "$test_root/security.out" >&2; fail_test 'Manual security apply failed.'; }
[ "$(tail -n 1 "$test_root/proxy-calls")" = true,true ] || fail_test 'Manual security apply skipped recreation/readiness checks.'
snapshot="$(cat "$FULL_BACKUP_FILE")"
cmp -s "$config/settings.csv" "$snapshot/domains/example.com/runtime/applied/settings.csv" || fail_test 'Security backup has stale applied settings.'

# A failed automatic backup is a failed apply: restore active snapshots/runtime
# while retaining the operator's manual edit and the last good backup pointer.
before_pointer="$snapshot"
before_checksum="$(cat "$FULL_BACKUP_CHECKSUM_FILE")"
cp "$applied/headers.csv" "$test_root/before-headers.csv"
cp "$test_root/runtime-headers" "$test_root/runtime-before"
_domain_csv_write_header "$config/headers.csv"
csv_join_row response X-Revision retry-later >>"$config/headers.csv"
FAIL_SNAPSHOT=true
if apply_domain_config example.com >"$test_root/failure.out" 2>&1; then fail_test 'Failed final snapshot committed manual apply.'; fi
FAIL_SNAPSHOT=false
grep -q 'Rolled back\.' "$test_root/failure.out" || { cat "$test_root/failure.out" >&2; fail_test 'Failed snapshot did not complete rollback.'; }
cmp -s "$applied/headers.csv" "$test_root/before-headers.csv" || fail_test 'Failed snapshot left changed applied headers.'
cmp -s "$test_root/runtime-headers" "$test_root/runtime-before" || fail_test 'Failed snapshot left changed proxy state.'
grep -q 'retry-later' "$config/headers.csv" || fail_test 'Rollback overwrote manual draft edits.'
[ "$(cat "$FULL_BACKUP_FILE")" = "$before_pointer" ] && [ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$before_checksum" ] || fail_test 'Failed snapshot replaced committed backup metadata.'
! domain_config_runtime_recovery_pending || fail_test 'Rollback left unfinished runtime recovery.'
printf '[tests] domain_config_manual_apply.sh: PASS\n'
