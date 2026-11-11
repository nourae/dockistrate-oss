#!/usr/bin/env bash
# Runtime configuration is consumed by the production command functions.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils backups security_rules cli/run_command domain_config/dispatch; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/security-rule-actions.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state" CONFIG_DIR="$STATE_DIR/config" TMP_DIR="$STATE_DIR/tmp"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 127.0.0.1:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend other.example.com 127.0.0.1:8081 dockistrate-net >>"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function dockistrate_command_skips_runtime_prep() { return 0; }
function _config_begin_transaction_if_needed() { printf -v "$1" '%s' false; }
function _config_end_transaction_if_started() { :; }
function create_backup() { :; }
function update_nginx_config_for_security_change() { :; }
function assert_field() {
  csv_parse_line "$(_sr_load_line "$1")" || fail_test 'Could not read saved rule'
  [ "${CSV_FIELDS[$2]}" = "$3" ] || fail_test "Rule $1 field $2 should be $3"
}
function run_cli() { _run_command_impl "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "Command failed: $*"; }; }

# Exercise real command dispatch and parsers, with only runtime/backup effects
# replaced. Flag-looking condition values must keep their exact boundaries.
run_cli add-security-rule example.com 1 header X-Guard equals --action
assert_field 1 47 require
assert_field 1 8 --action
run_cli add-security-rule other.example.com 2 --action block \
  header X-Test equals --code --mode or method - equals GET --code 451
assert_field 2 47 block
assert_field 2 8 --code
run_cli add-security-rule example.com 2 header X-Trusted equals 'quoted, "value"' \
  arg exception equals --domain --mode and --action allow --code 409 --reason saved --loc saved-location
assert_field 3 47 allow
assert_field 3 8 'quoted, "value"'
assert_field 3 12 --domain

run_cli update-security-rule 1 --action allow
run_cli update-security-rule 1 --code 418
assert_field 1 47 allow
assert_field 1 3 418
run_cli update-security-rule 2 --count 1 header X-Test equals --action --action require
assert_field 2 47 require
assert_field 2 8 --action
run_cli move-security-rule 3 1
run_cli duplicate-security-rule 1
run_cli disable-security-rule 1
run_cli enable-security-rule 1
run_cli set-security-rule-mode 1 or
assert_field 1 47 allow
assert_field 1 2 or
assert_field 1 3 409
assert_field 1 45 saved
assert_field 1 46 saved-location
assert_field 4 47 allow
run_cli list-security-rules other.example.com
grep -q '^3: .*other.example.com.*action=require' "$TEST_WORK/output" || fail_test 'Filtered listing renumbered the global rule ID or hid its action'
if grep -q '^1:' "$TEST_WORK/output"; then fail_test 'Filtered listing used local numbering'; fi
run_cli list-security-rules example.com
grep -q 'action=allow' "$TEST_WORK/output" || fail_test 'Listing omitted Allow action'
grep -q 'retained but unused' "$TEST_WORK/output" || fail_test 'Allow listing presented rejection metadata as active'

cp "$SECURITY_RULES_DB" "$TEST_WORK/before"
for command in add update; do
  if [ "$command" = add ]; then
    if (_run_command_impl add-security-rule example.com 1 path - equals / --action invalid) >"$TEST_WORK/rejected" 2>&1; then fail_test 'Add accepted an invalid action'; fi
  else
    if (_run_command_impl update-security-rule 1 --action invalid) >"$TEST_WORK/rejected" 2>&1; then fail_test 'Update accepted an invalid action'; fi
  fi
  cmp -s "$SECURITY_RULES_DB" "$TEST_WORK/before" || fail_test 'Invalid action changed saved state'
done
conditions=()
for ((i = 0; i < 10; i++)); do conditions+=(header X-Test equals --action); done
run_cli add-security-rule example.com 10 "${conditions[@]}" --mode and --action block
assert_field 5 4 10
assert_field 5 44 --action
if (_run_command_impl add-security-rule example.com 11 "${conditions[@]}" --mode and --action block) >"$TEST_WORK/rejected" 2>&1; then fail_test 'Add accepted more than ten conditions'; fi

# Pending-edit review must skip action flags and complete condition groups when
# identifying the actual destination domain of an update.
function _domain_config_guard_pending() { printf '%s\n' "$1" >>"$TEST_WORK/guarded"; }
function _domain_config_guard_command_domain() { printf '%s\n' "$1" >>"$TEST_WORK/guarded"; }
_domain_config_command_guard update-security-rule 1 --action block --count 1 header X-Test equals --domain --domain other.example.com
[ "$(cat "$TEST_WORK/guarded")" = $'example.com\nother.example.com' ] || fail_test 'Pending-edit guard mistook condition data or action metadata for a domain'

__dockistrate_completion_handlers=()
source "$ROOT_DIR/completion/commands/_dockistrate_complete_00_security_rules.sh"
function __dockistrate_acl_domains() { printf '%s\n' example.com other.example.com; }
cur='' cword=9 words=(dockistrate.sh add-security-rule example.com 1 header X-Test equals --action --action '')
_dockistrate_complete_security_rules add-security-rule
[ "${COMPREPLY[*]}" = 'require block allow' ] || fail_test 'Action value completion is missing'
cur='' cword=8 words=(dockistrate.sh add-security-rule example.com 1 header X-Test equals --action '')
_dockistrate_complete_security_rules add-security-rule
case " ${COMPREPLY[*]} " in *' --action '*) ;; *) fail_test 'Literal --action condition value confused option completion' ;; esac
cur='' cword=8 words=(dockistrate.sh update-security-rule 1 --count 1 header X-Test equals '')
_dockistrate_complete_security_rules update-security-rule
[ "${#COMPREPLY[@]}" -eq 0 ] || fail_test 'Completion offered metadata in a condition-value slot'
printf '[PASS] security-rule CLI actions preserve argument boundaries, metadata and global IDs\n'
