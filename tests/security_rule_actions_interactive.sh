#!/usr/bin/env bash
# Prompt variables are assigned dynamically by the production collectors.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils security_rules cli/common cli/arg_choices_security cli/summarize_cond cli/security_rule_interactive_common cli/security_rule_add_interactive cli/security_rule_update_interactive; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/security-rule-action-menu.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
INTERACTIVE=true SECURITY_RULE_STATUS=403
PROMPT_ARGS_COLLECTED=() SELECTED_ARGS=() SELECTED_CMD=''
MENU_ACTION=default CODE_PROMPTS=0 CODE_INPUT='' ACTION_OPTIONS=() EVENTS=()
CURRENT_RULE=''

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function get_arg_choices() {
  case "$2" in
  action) __arg_choices_action "$1" ;;
  domain) printf '%s\n' 'example.com|example.com' ;;
  id) printf '%s\n' '7|Rule 7' ;;
  mode) printf 'and\nor\n' ;;
  esac
}
function choose_option() {
  local output="$1" prompt="$2" option='' chosen=0 position=0
  shift 2
  EVENTS+=("$prompt")
  case "$prompt" in *'Create security rule?'*) printf '%s\n' "$prompt" ;; esac
  if [ "$prompt" = 'Rule action:' ]; then
    ACTION_OPTIONS=("$@")
    [ "$MENU_ACTION" != cancel ] || return 1
    if [ "$MENU_ACTION" != default ]; then
      chosen=-1
      for option in "$@"; do
        case "$MENU_ACTION:$option" in
        block:Block* | require:Require* | allow:Allow*) chosen="$position" ;;
        esac
        position=$((position + 1))
      done
      [ "$chosen" -ge 0 ] || fail_test 'Requested action is missing from menu'
    fi
  fi
  printf -v "$output" '%s' "$chosen"
}
function read_with_editing() {
  local prompt="$1" output="$2" preset="${3:-}"
  EVENTS+=("$prompt")
  case "$prompt" in
  'Number of conditions'*) printf -v "$output" '%s' 1 ;;
  'Status code override'*) CODE_PROMPTS=$((CODE_PROMPTS + 1)); printf -v "$output" '%s' "$CODE_INPUT" ;;
  *) printf -v "$output" '%s' "$preset" ;;
  esac
}
function is_back_input() { return 1; }
function domain_exists() { [ "$1" = example.com ]; }
function _sr_load_line() { printf '%s\n' "$CURRENT_RULE"; }
function _sr_collect_condition_quads() {
  EVENTS+=(conditions)
  SR_COLLECTED_CONDS=(header X-Test equals --action)
  SR_COLLECTED_SUMMARIES=('header:X-Test equals --action')
}
function reset_prompt() { CODE_PROMPTS=0; CODE_INPUT=''; EVENTS=(); ACTION_OPTIONS=(); PROMPT_ARGS_COLLECTED=(); }
function saved_rule() {
  CURRENT_RULE="$(_sr_write_db_line_with_action "$1" 1 example.com single 451 1 saved-note saved-location header X-Test equals --action)"
}
function assert_args() {
  local position=0 expected=''
  [ "$#" -eq "${#PROMPT_ARGS_COLLECTED[@]}" ] || fail_test 'Interactive argument count differs from CLI shape'
  for expected in "$@"; do
    [ "$expected" = "${PROMPT_ARGS_COLLECTED[position]}" ] || fail_test "Interactive argument mismatch at position $position"
    position=$((position + 1))
  done
}

reset_prompt
MENU_ACTION=default CODE_INPUT=451
prompt_args_handle_add_security_rule_interactive add-security-rule >"$TEST_WORK/output"
assert_args example.com 1 header X-Test equals --action --action block --code 451
[ "$CODE_PROMPTS" -eq 1 ] || fail_test 'Block did not request rejection status'
[ "${EVENTS[0]}" = 'Select domain:' ] && [ "${EVENTS[1]}" = 'Rule action:' ] || fail_test 'Action is not collected immediately after the domain'
case "${ACTION_OPTIONS[0]}" in 'Block when conditions match (recommended'*) ;; *) fail_test 'New-rule default is not the recommended Block action' ;; esac
grep -q 'Action: block' "$TEST_WORK/output" || fail_test 'Create review omitted the action'
grep -q 'never bypasses Require rules, ACLs, or mTLS' "$TEST_WORK/output" || fail_test 'Action picker omitted precedence explanation'

reset_prompt
MENU_ACTION=allow
prompt_args_handle_add_security_rule_interactive add-security-rule >"$TEST_WORK/output"
assert_args example.com 1 header X-Test equals --action --action allow
[ "$CODE_PROMPTS" -eq 0 ] || fail_test 'Allow asked for irrelevant rejection status'
grep -q 'Rejection: none' "$TEST_WORK/output" || fail_test 'Allow review described an active rejection'

reset_prompt
MENU_ACTION=cancel
if prompt_args_handle_add_security_rule_interactive add-security-rule >"$TEST_WORK/output"; then fail_test 'Action cancellation continued creation'; fi
[ "${#PROMPT_ARGS_COLLECTED[@]}" -eq 0 ] && [ "$CODE_PROMPTS" -eq 0 ] || fail_test 'Action cancellation collected later input'

reset_prompt
saved_rule require
MENU_ACTION=default
if prompt_args_handle_update_security_rule_interactive update-security-rule >"$TEST_WORK/output"; then fail_test 'Unchanged update did not retain current action'; fi
case "${ACTION_OPTIONS[0]}" in 'Require conditions to match (current)') ;; *) fail_test 'Update silently defaulted to a new action' ;; esac

reset_prompt
saved_rule block
MENU_ACTION=allow
prompt_args_handle_update_security_rule_interactive update-security-rule >"$TEST_WORK/output"
assert_args 7 --action allow
[ "$CODE_PROMPTS" -eq 0 ] || fail_test 'Switching to Allow requested rejection status'
grep -q 'action=allow' "$TEST_WORK/output" || fail_test 'Update review omitted new action'

reset_prompt
saved_rule allow
MENU_ACTION=require
prompt_args_handle_update_security_rule_interactive update-security-rule >"$TEST_WORK/output"
assert_args 7 --action require
[ "$CODE_PROMPTS" -eq 1 ] || fail_test 'Switching back to Require did not offer rejection status'
grep -q 'Rejection metadata: retained (status=451)' "$TEST_WORK/output" || fail_test 'Allow hid its retained rejection metadata'
printf '[PASS] interactive actions preserve existing choices, explain precedence and skip Allow rejection prompts\n'
