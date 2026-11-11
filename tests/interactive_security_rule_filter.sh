#!/usr/bin/env bash
# Runtime and prompt variables are consumed by the sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils security_rules cli; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/interactive-rule-filter.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK" CONFIG_DIR="$TEST_WORK/config"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
mkdir -p "$CONFIG_DIR"
function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function docker() { fail_test 'Listing prompt attempted Docker'; }
function backend_aliases_file() { printf '%s\n' "$BACKEND_ALIASES_FILE"; }
function dockistrate_prepare_runtime() { fail_test 'Listing prompt prepared runtime'; }
{
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER"
  state_backend_ports_row_backend example.com backend-example:80 dockistrate-net
} >"$BACKEND_PORTS_FILE"
{
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER"
  csv_join_row alias alias.example.com example.com
  csv_join_row dedicated dedicated.example.com example.com
} >"$BACKEND_ALIASES_FILE"
{
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER"
  _sr_write_db_line_with_action require 1 example.com single 403 1 - auto header X-Test equals yes
  _sr_write_db_line_with_action block 1 alias.example.com single 403 1 - auto header User-Agent contains BadBot
  _sr_write_db_line_with_action allow 1 dedicated.example.com single 403 1 - auto header X-Test equals yes
} >"$SECURITY_RULES_DB"

choices="$(__arg_choices_security_rule_domain)"
expected=$'__ALL__|All domains\nalias.example.com\ndedicated.example.com\nexample.com\n__MANUAL__|Enter a domain manually...'
[ "$choices" = "$expected" ] || fail_test 'Domain choices omitted owners or all/manual entry'
INTERACTIVE=true VERBOSE=false DOCKISTRATE_NO_CLEAR=true
# Exercise actual selection keys, generic collection and postprocessing.
prompt_args_for_command list-security-rules >"$TEST_WORK/all" <<< '' || fail_test 'All-domain prompt failed'
[ "$SELECTED_CMD" = list-security-rules ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'All domains did not produce no arguments'
if grep -Fq 'Review command' "$TEST_WORK/all"; then fail_test 'Read-only listing requested mutation review'; fi
for entry in '2 alias.example.com 2' '3 dedicated.example.com 3' '4 example.com 1'; do
  read -r key domain global_id <<< "$entry"
  prompt_args_for_command list-security-rules >"$TEST_WORK/choice" <<< "$key" || fail_test 'Domain prompt failed'
  [ "${#SELECTED_ARGS[@]}" -eq 1 ] && [ "${SELECTED_ARGS[0]}" = "$domain" ] || fail_test 'Selected domain was changed'
  list_security_rules "${SELECTED_ARGS[@]}" >"$TEST_WORK/list"
  grep -Eq "^${global_id}: .*${domain}" "$TEST_WORK/list" || fail_test 'Filtered listing changed global IDs'
  [ "$(grep -c '^[0-9]:' "$TEST_WORK/list")" -eq 1 ] || fail_test 'Filter included other or inherited owners'
done
prompt_args_for_command list-security-rules >"$TEST_WORK/manual" <<< $'5\nALIAS.EXAMPLE.COM\n' || fail_test 'Manual domain prompt failed'
[ "${SELECTED_ARGS[0]}" = alias.example.com ] || fail_test 'Manual domain was not normalized'
if prompt_args_for_command list-security-rules >"$TEST_WORK/cancel" <<< q; then fail_test 'Cancellation selected a command'; fi
[ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'Cancellation retained selection'
for eof_input in '' $'5\n' $'5\npartial.example.com'; do
  if prompt_args_for_command list-security-rules >"$TEST_WORK/eof" < <(printf '%s' "$eof_input"); then
    fail_test 'Menu/manual-entry EOF selected a listing'
  fi
  [ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] && [ "${#PROMPT_ARGS_COLLECTED[@]}" -eq 0 ] ||
    fail_test 'EOF retained executable listing arguments'
done
prompt_args_for_command list-security-rules >"$TEST_WORK/manual-blank" < <(printf '5\n\n') || fail_test 'Intentional manual blank did not select All domains'
[ "$SELECTED_CMD" = list-security-rules ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'Intentional blank changed the listing default'

__dockistrate_completion_handlers=()
# shellcheck source=../completion/commands/_dockistrate_complete_00_security_rules.sh
source "$ROOT_DIR/completion/commands/_dockistrate_complete_00_security_rules.sh"
function __dockistrate_acl_domains() { __arg_choices_acl_domains; }
cur='' cword=2 words=(dockistrate.sh list-security-rules '')
_dockistrate_complete_security_rules list-security-rules
[ "${COMPREPLY[*]}" = 'alias.example.com dedicated.example.com example.com' ] || fail_test 'CLI domain completion omitted aliases or dedicated hosts'
cword=3
_dockistrate_complete_security_rules list-security-rules
[ "${#COMPREPLY[@]}" -eq 0 ] || fail_test 'Listing completed extra arguments'

# Exercise the generic text and multiline paths with actual input helpers.
# Only the fixture command schema/choices and review are replaced.
function get_arg_spec() {
  case "$1" in
  plain-eof) printf 'value,fallback' ;;
  multiline-eof) printf 'docker_opts,--cpus 2' ;;
  manual-multiline-eof) printf 'docker_opts,' ;;
  *) return 1 ;;
  esac
}
function get_arg_choices() {
  if [ "$1" = manual-multiline-eof ]; then printf '__MANUAL__|Enter manually...\n'; fi
}
function review_command_before_run() { return 0; }
for command in plain-eof multiline-eof manual-multiline-eof; do
  if [ "$command" = manual-multiline-eof ]; then eof_input=$'\n'; else eof_input=''; fi
  if prompt_args_for_command "$command" >"$TEST_WORK/generic-eof" < <(printf '%s' "$eof_input"); then
    fail_test "EOF accepted $command"
  fi
  [ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'Generic EOF retained selection'
done
prompt_args_for_command plain-eof >"$TEST_WORK/plain-blank" <<< '' || fail_test 'Intentional blank lost its default'
[ "${SELECTED_ARGS[0]}" = fallback ] || fail_test 'Plain-text blank did not keep its default'
INTERACTIVE=false
prompt_args_for_command plain-eof >"$TEST_WORK/noninteractive-eof" </dev/null || fail_test 'Noninteractive EOF compatibility changed'
[ "${SELECTED_ARGS[0]}" = fallback ] || fail_test 'Noninteractive EOF lost its compatibility default'
printf '[tests] interactive_security_rule_filter.sh: PASS\n'
