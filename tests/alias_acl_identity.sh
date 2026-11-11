#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES=(
  alias_settings_fallback
  explicit_settings_override
  alias_activation
  disabled_rules_inherit
  explicit_rules_replace
  policy_only_alias_inherits_rules
  malformed_active_rules
  malformed_settings
  inherited_cidr_policy_transition
  inherited_cidr_status_transition
  inherited_primary_cidr_guard
  fallback_cidr_is_revalidated
  interactive_acl_domain_choices
  acl_domain_completion
  removal_render_failure_rolls_back
  removal_cleanup_failure_rolls_back
  removal_cleans_only_alias
)

if [ "$#" -eq 0 ]; then
  failed=0
  for test_case in "${CASES[@]}"; do
    if "$BASH" "${BASH_SOURCE[0]}" --case "$test_case"; then
      printf '[tests] PASS: alias ACL %s\n' "$test_case"
    else
      printf '[tests] FAIL: alias ACL %s\n' "$test_case" >&2
      failed=1
    fi
  done
  exit "$failed"
fi
[ "$#" -eq 2 ] && [ "$1" = --case ] || exit 2
case_found=false
for test_case in "${CASES[@]}"; do
  [ "$test_case" != "$2" ] || case_found=true
done
[ "$case_found" = true ] || exit 2

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"
# shellcheck source=../lib/security_rules.sh
source "$ROOT_DIR/lib/security_rules.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_alias_acl.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT
BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
CERTS_DIR="$STATE_DIR/certs"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
BACKUP_DIR="$STATE_DIR/backups"
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
SECURITY_RULES_DB="$SECURITY_RULES_FILE"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
ACL_POLICY=allow
ACL_STATUS=403
OUTPUT="$TMP_ROOT/output"
TRACE="$TMP_ROOT/trace"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$TMP_DIR" "$ERROR_LOG_DIR" \
  "$BACKUP_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR" "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" \
  'backend,primary.example.com,127.0.0.1:8080,dockistrate-net,,,,,,,,,,,,,,,,,' >"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'alias,alias.example.com,primary.example.com' \
  'alias,other.example.com,primary.example.com' >"$BACKEND_ALIASES_FILE"
printf '%s\n' "$STATE_BACKEND_ACL_POLICIES_HEADER" >"$BACKEND_ACL_POLICY_FILE"
printf '%s\n' "$STATE_BACKEND_ACL_STATUSES_HEADER" >"$BACKEND_ACL_STATUS_FILE"
printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_DB"

function log_msg() { :; }
function capture_docker_logs() { :; }
function load_config() { :; }
function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function expect_value() {
  local expected="$1" actual=""
  shift
  actual="$("$@")" || fail_test "Lookup failed: $*"
  [ "$actual" = "$expected" ] || fail_test "Expected '$expected', got '$actual' from $*"
}
function expect_status() {
  local expected="$1" actual=0
  shift
  "$@" >"$OUTPUT" 2>&1 || actual=$?
  [ "$actual" -eq "$expected" ] || fail_test "Expected status $expected, got $actual from $*"
}
function write_rules() {
  printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" "$@" >"$SECURITY_IP_RULES_DB"
}
function assert_contains() {
  grep -Fq -- "$2" "$1" || fail_test "Missing '$2' in $1"
}
function assert_absent() {
  if grep -Fq -- "$2" "$1"; then
    fail_test "Unexpected '$2' in $1"
  fi
}

function alias_settings_fallback() {
  printf '%s\n' 'primary.example.com,deny' >>"$BACKEND_ACL_POLICY_FILE"
  printf '%s\n' 'primary.example.com,451' >>"$BACKEND_ACL_STATUS_FILE"
  expect_value deny get_backend_acl_policy ALIAS.EXAMPLE.COM
  expect_value 451 get_backend_acl_status ALIAS.EXAMPLE.COM
  expect_value allow get_backend_acl_policy unrelated.example.com
  expect_value 403 get_backend_acl_status unrelated.example.com
  expect_status 1 _alias_has_explicit_acl alias.example.com
}

function explicit_settings_override() {
  printf '%s\n' 'primary.example.com,deny' 'alias.example.com,allow' >>"$BACKEND_ACL_POLICY_FILE"
  printf '%s\n' 'primary.example.com,451' 'alias.example.com,429' >>"$BACKEND_ACL_STATUS_FILE"
  expect_value allow get_backend_acl_policy alias.example.com
  expect_value 429 get_backend_acl_status alias.example.com
  expect_value deny get_backend_acl_policy other.example.com
  expect_value 451 get_backend_acl_status other.example.com
  expect_status 0 _alias_has_explicit_acl alias.example.com
}

function alias_activation() {
  local scope
  for scope in l7 l3 both L7 L3 BOTH Both; do
    write_rules "1,alias.example.com,$scope,deny,192.0.2.5,403"
    expect_status 0 _alias_has_explicit_acl alias.example.com
  done
  write_rules '0,alias.example.com,l7,deny,192.0.2.5,403'
  expect_status 1 _alias_has_explicit_acl alias.example.com
  printf '%s\n' 'alias.example.com,allow' >>"$BACKEND_ACL_POLICY_FILE"
  expect_status 0 _alias_has_explicit_acl alias.example.com
  printf '%s\n' "$STATE_BACKEND_ACL_POLICIES_HEADER" >"$BACKEND_ACL_POLICY_FILE"
  printf '%s\n' 'alias.example.com,403' >>"$BACKEND_ACL_STATUS_FILE"
  expect_status 0 _alias_has_explicit_acl alias.example.com
}

function disabled_rules_inherit() {
  write_rules '1,primary.example.com,l7,deny,192.0.2.10,403' \
    '0,alias.example.com,l7,deny,192.0.2.11,403'
  _build_security_ip_for_domain alias.example.com >"$OUTPUT"
  assert_contains "$OUTPUT" 'deny 192.0.2.10;'
  assert_absent "$OUTPUT" '192.0.2.11'
  expect_status 1 _alias_has_explicit_acl alias.example.com
}

function explicit_rules_replace() {
  write_rules '1,primary.example.com,l7,deny,192.0.2.10,403' \
    '1,alias.example.com,l7,deny,192.0.2.11,403'
  _build_security_ip_for_domain alias.example.com >"$OUTPUT"
  assert_contains "$OUTPUT" 'deny 192.0.2.11;'
  assert_absent "$OUTPUT" '192.0.2.10'
  _build_security_ip_for_domain other.example.com >"$OUTPUT"
  assert_contains "$OUTPUT" 'deny 192.0.2.10;'
  assert_absent "$OUTPUT" '192.0.2.11'
}

function policy_only_alias_inherits_rules() {
  write_rules '1,primary.example.com,l7,deny,192.0.2.10,403'
  printf '%s\n' 'alias.example.com,allow' >>"$BACKEND_ACL_POLICY_FILE"
  expect_status 0 _alias_has_explicit_acl alias.example.com
  _build_security_ip_for_domain alias.example.com >"$OUTPUT"
  assert_contains "$OUTPUT" 'deny 192.0.2.10;'
}

function malformed_active_rules() {
  local row
  for row in \
    '1,alias.example.com,invalid,deny,192.0.2.5,403' \
    '1,alias.example.com,l7,invalid,192.0.2.5,403' \
    '1,alias.example.com,l7,deny,192.0.2.999,403' \
    '1,alias.example.com,l7,deny,192.0.2.5,999' \
    '1,alias.example.com,l3,deny,192.0.2.0/24,403' \
    '1,alias.example.com,l7,deny,192.0.2.5,403,extra'; do
    write_rules "$row"
    cp "$SECURITY_IP_RULES_DB" "$TMP_ROOT/rules-before"
    expect_status 2 _alias_has_explicit_acl alias.example.com
    cmp -s "$TMP_ROOT/rules-before" "$SECURITY_IP_RULES_DB" || fail_test 'Validation changed malformed ACL state'
  done
}

function malformed_settings() {
  local actual=""
  printf '%s\n' 'primary.example.com,invalid' >>"$BACKEND_ACL_POLICY_FILE"
  if actual="$(get_backend_acl_policy alias.example.com 2>"$OUTPUT")"; then
    fail_test 'Alias silently accepted malformed inherited policy'
  fi
  [ -z "$actual" ] || fail_test 'Malformed policy emitted fallback policy'
  [ -s "$OUTPUT" ] || fail_test 'Malformed inherited policy lacked diagnostic'
  expect_status 2 _alias_has_explicit_acl alias.example.com
}

function inherited_cidr_policy_transition() {
  write_rules '1,alias.example.com,l7,allow,192.0.2.0/24,'
  printf '%s\n' 'primary.example.com,452' >>"$BACKEND_ACL_STATUS_FILE"
  expect_status 1 _sr_validate_backend_acl_policy_transition primary.example.com deny 403
  assert_contains "$OUTPUT" 'alias.example.com'
  printf '%s\n' 'alias.example.com,allow' >>"$BACKEND_ACL_POLICY_FILE"
  expect_status 0 _sr_validate_backend_acl_policy_transition primary.example.com deny 403
}

function inherited_cidr_status_transition() {
  write_rules '1,alias.example.com,l7,allow,192.0.2.0/24,'
  printf '%s\n' 'primary.example.com,deny' >>"$BACKEND_ACL_POLICY_FILE"
  expect_status 1 _sr_validate_backend_acl_status_transition primary.example.com 452 allow
  assert_contains "$OUTPUT" 'alias.example.com'
  printf '%s\n' 'alias.example.com,403' >>"$BACKEND_ACL_STATUS_FILE"
  expect_status 0 _sr_validate_backend_acl_status_transition primary.example.com 452 allow
}

function inherited_primary_cidr_guard() {
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,'
  printf '%s\n' 'alias.example.com,deny' >>"$BACKEND_ACL_POLICY_FILE"
  expect_status 1 _sr_validate_backend_acl_status_transition alias.example.com 452 allow
  assert_contains "$OUTPUT" 'alias.example.com'
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,alias.example.com,l7,allow,192.0.2.5,'
  expect_status 0 _sr_validate_backend_acl_status_transition alias.example.com 452 allow
}

function fallback_cidr_is_revalidated() {
  printf '%s\n' 'alias.example.com,deny' >>"$BACKEND_ACL_POLICY_FILE"
  printf '%s\n' 'alias.example.com,452' >>"$BACKEND_ACL_STATUS_FILE"
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,alias.example.com,l7,allow,192.0.2.5,'
  build_security_ip_includes >"$OUTPUT" 2>&1 || fail_test 'Explicit exact-IP alias policy could not render'
  assert_contains "$SECURITY_IP_DIR/alias.example.com.inc" '192.0.2.5'
  local state
  for state in disabled removed; do
    if [ "$state" = disabled ]; then
      write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
        '0,alias.example.com,l7,allow,192.0.2.5,'
    else
      write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,'
    fi
    cp "$SECURITY_IP_RULES_DB" "$TMP_ROOT/rules-before"
    expect_status 1 build_security_ip_includes
    assert_contains "$OUTPUT" 'requires status 403'
    assert_contains "$OUTPUT" 'alias.example.com'
    cmp -s "$TMP_ROOT/rules-before" "$SECURITY_IP_RULES_DB" || fail_test 'Rejected fallback changed persisted ACL rows'
  done
}

function seed_domain_choices() {
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
    'alias,alias.example.com,primary.example.com' \
    '"alias","OTHER.EXAMPLE.COM","primary.example.com"' \
    'dedicated,dedicated.example.com,primary.example.com' \
    'alias,wrong-columns.example.com,primary.example.com,extra' \
    'alias,"unterminated.example.com,primary.example.com' \
    'other,wrong-kind.example.com,primary.example.com' >"$BACKEND_ALIASES_FILE"
  write_rules '0,alias.example.com,l7,deny,192.0.2.5,403'
  printf '%s\n' alias.example.com dedicated.example.com other.example.com primary.example.com >"$TMP_ROOT/expected-domains"
}

function interactive_acl_domain_choices() {
  # Source only the choice functions, without interactive initialization.
  # shellcheck source=../lib/cli/get_arg_choices.sh
  source "$ROOT_DIR/lib/cli/get_arg_choices.sh"
  # shellcheck source=../lib/cli/arg_choices_misc.sh
  source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"
  # shellcheck source=../lib/cli/arg_choices_security.sh
  source "$ROOT_DIR/lib/cli/arg_choices_security.sh"
  seed_domain_choices
  local command
  for command in add-acl add-security-ip update-acl update-security-ip set-backend-acl-policy set-backend-acl-status; do
    get_arg_choices "$command" domain >"$OUTPUT"
    cmp -s "$TMP_ROOT/expected-domains" "$OUTPUT" || fail_test "Incorrect ACL domain choices for $command"
  done
  expect_value primary.example.com get_arg_choices start-backend domain
}

function acl_domain_completion() {
  local __dockistrate_completion_handlers=() COMPREPLY=() cur="" prev="" cword=2 command
  # shellcheck source=../completion/commands/__dockistrate_backend_domains.sh
  source "$ROOT_DIR/completion/commands/__dockistrate_backend_domains.sh"
  # shellcheck source=../completion/commands/__dockistrate_complete_backend_domains.sh
  source "$ROOT_DIR/completion/commands/__dockistrate_complete_backend_domains.sh"
  # shellcheck source=../completion/commands/_dockistrate_complete_backend_domain_commands.sh
  source "$ROOT_DIR/completion/commands/_dockistrate_complete_backend_domain_commands.sh"
  seed_domain_choices
  for command in add-acl set-backend-acl-policy set-backend-acl-status update-acl; do
    cword=2
    prev=""
    if [ "$command" = update-acl ]; then
      cword=4
      prev=--domain
    fi
    COMPREPLY=(_not_completed_)
    _dockistrate_complete_backend_domain_commands "$command" || fail_test "ACL completion did not handle $command"
    printf '%s\n' "${COMPREPLY[@]}" >"$OUTPUT"
    cmp -s "$TMP_ROOT/expected-domains" "$OUTPUT" || fail_test "Incorrect ACL domain completion for $command"
  done
  cword=2
  prev=""
  COMPREPLY=(_not_completed_)
  _dockistrate_complete_backend_domain_commands start-backend || fail_test 'Backend completion stopped handling start-backend'
  [ "${COMPREPLY[*]}" = primary.example.com ] || fail_test 'ACL target expansion affected start-backend completion'
}

function seed_removal() {
  write_rules '1,primary.example.com,l7,deny,192.0.2.10,403' \
    '1,alias.example.com,l7,deny,192.0.2.11,403' \
    '0,alias.example.com,l7,deny,192.0.2.12,403' \
    '1,other.example.com,l7,deny,192.0.2.13,403'
  printf '%s\n' 'alias.example.com,allow' 'other.example.com,deny' >>"$BACKEND_ACL_POLICY_FILE"
  printf '%s\n' 'alias.example.com,451' 'other.example.com,429' >>"$BACKEND_ACL_STATUS_FILE"
  printf 'alias http\n' >"$SECURITY_IP_DIR/alias.example.com.inc"
  printf 'alias stream\n' >"$SECURITY_IP_STREAM_DIR/alias.example.com.inc"
  printf 'keep other\n' >"$SECURITY_IP_DIR/other.example.com.inc"
  chmod 600 "$BACKEND_ALIASES_FILE" "$SECURITY_IP_RULES_DB" "$BACKEND_ACL_POLICY_FILE" "$BACKEND_ACL_STATUS_FILE"
  cp -pR "$CONFIG_DIR" "$TMP_ROOT/config-before"
}

function assert_removal_rolled_back() {
  diff -r "$TMP_ROOT/config-before" "$CONFIG_DIR" >"$TMP_ROOT/diff" || fail_test 'Failed alias removal changed persisted state or includes'
  [ ! -e "$TMP_DIR/.dockistrate_transaction.lock" ] || fail_test 'Failed alias removal retained transaction lock'
}

function removal_render_failure_rolls_back() {
  seed_removal
  function create_backup() { :; }
  function update_nginx_config_for_security_change() {
    printf 'render reached\n' >"$TRACE"
    [ ! -f "$SECURITY_IP_DIR/alias.example.com.inc" ] || return 2
    return 1
  }
  if (remove_host_alias alias.example.com) >"$OUTPUT" 2>&1; then
    fail_test 'Alias removal reported success after render failure'
  fi
  assert_contains "$TRACE" 'render reached'
  assert_contains "$OUTPUT" 'Rolled back.'
  assert_removal_rolled_back
}

function removal_cleanup_failure_rolls_back() {
  seed_removal
  function safe_rm_f() {
    printf 'cleanup reached\n' >"$TRACE"
    return 1
  }
  if (remove_host_alias alias.example.com) >"$OUTPUT" 2>&1; then
    fail_test 'Alias removal reported success after cleanup failure'
  fi
  assert_contains "$TRACE" 'cleanup reached'
  assert_contains "$OUTPUT" 'Rolled back.'
  assert_removal_rolled_back
}

function removal_cleans_only_alias() {
  seed_removal
  function create_backup() { :; }
  function update_nginx_config_for_security_change() { printf 'security refresh\n' >"$TRACE"; }
  (remove_host_alias alias.example.com) >"$OUTPUT" 2>&1 || fail_test 'Alias removal failed'
  local file
  for file in "$BACKEND_ALIASES_FILE" "$SECURITY_IP_RULES_DB" "$BACKEND_ACL_POLICY_FILE" "$BACKEND_ACL_STATUS_FILE"; do
    assert_absent "$file" 'alias.example.com'
    assert_contains "$file" 'other.example.com'
  done
  assert_contains "$SECURITY_IP_RULES_DB" 'primary.example.com'
  assert_contains "$SECURITY_IP_DIR/other.example.com.inc" 'keep other'
  [ ! -e "$SECURITY_IP_DIR/alias.example.com.inc" ] || fail_test 'Alias HTTP include survived removal'
  [ ! -e "$SECURITY_IP_STREAM_DIR/alias.example.com.inc" ] || fail_test 'Alias stream include survived removal'
  assert_contains "$TRACE" 'security refresh'
}

"$2"
