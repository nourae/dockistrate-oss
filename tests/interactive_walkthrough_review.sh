#!/usr/bin/env bash
# Fixture variables are consumed by the real prompt and rendering helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils security_rules cli; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/interactive-walkthrough-review.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
INTERACTIVE=true
VERBOSE=false
DOCKISTRATE_NO_CLEAR=false
CLI_CLEAR_SCREEN_AVAILABLE=true
function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function docker() { fail_test 'Prompt review attempted Docker'; }
function clear() { printf '[CLEAR]\n'; }

_review_command_format_prompt add-port example.com 443 80 https none no \
  --http3 off --alt-svc auto >"$TEST_WORK/port"
for expected in 'Listen port: 443' 'Backend container port: 80' 'WebSocket: no' 'HTTP/3: off' 'Alt-Svc: auto' \
  './dockistrate.sh add-port example.com 443 80 https none no --http3 off --alt-svc auto'; do
  grep -Fq -- "$expected" "$TEST_WORK/port" || fail_test "Port review omitted $expected"
done
if grep -Eq 'HTTP/3: --|Alt-Svc: off|Argument [0-9]+' "$TEST_WORK/port"; then
  fail_test 'Port review treated flag tokens as values'
fi
custom='h3=":443"; ma=86400'
_review_command_format_arg_summary add-port example.com 443 80 https example.com/selfsigned-443 yes \
  --alt-svc "$custom" --http3 on >"$TEST_WORK/custom"
grep -Fq "Alt-Svc: $custom" "$TEST_WORK/custom" || fail_test 'Custom Alt-Svc boundaries were lost'
grep -Fq 'HTTP/3: on' "$TEST_WORK/custom" || fail_test 'Reordered options were not parsed'
_review_command_format_arg_summary add-port example.com 443 80 https none no >"$TEST_WORK/defaults"
grep -Fq 'HTTP/3: off' "$TEST_WORK/defaults" || fail_test 'Omitted HTTP/3 default was not shown'
_review_command_format_arg_summary update-port example.com 443 --http3 off --alt-svc auto >"$TEST_WORK/update"
grep -Fq 'HTTP/3: off' "$TEST_WORK/update" || fail_test 'Existing update-port summary regressed'
grep -Fq 'Alt-Svc: auto' "$TEST_WORK/update" || fail_test 'Existing update-port Alt-Svc summary regressed'

# Keep the actual confirmation chooser/render loop, including screen clears
# and Help returning to a redraw. Earlier answers are fixed fixture inputs.
function _sr_prompt_domain() { printf -v "$1" '%s' example.com; }
function _sr_prompt_action() { printf -v "$1" '%s' "$TEST_ACTION"; }
function _sr_prompt_count() { printf -v "$1" '%s' 1; }
function _sr_prompt_code_optional() { printf -v "$1" '%s' 403; }
function _sr_collect_condition_quads() {
  SR_COLLECTED_CONDS=(header User-Agent contains "$TEST_CONDITION")
  SR_COLLECTED_SUMMARIES=("header:User-Agent contains $TEST_CONDITION")
}
TEST_ACTION=block
TEST_CONDITION=BadBot
PROMPT_ARGS_COLLECTED=()
prompt_args_handle_add_security_rule_interactive add-security-rule >"$TEST_WORK/confirm" <<< $'?\n\n'
awk '/^\[CLEAR\]$/ { text=""; next } { text=text $0 "\n" } END { printf "%s", text }' \
  "$TEST_WORK/confirm" >"$TEST_WORK/final-screen"
for expected in 'Security rule summary' 'Domain: example.com' 'Action: block' 'Conditions: 1' \
  'Code: 403' 'header:User-Agent contains BadBot' 'Create security rule?' '1) Confirm'; do
  grep -Fq "$expected" "$TEST_WORK/final-screen" || fail_test "Final confirmation screen omitted $expected"
done
[ "${PROMPT_ARGS_COLLECTED[7]}" = block ] || fail_test 'Confirmed rule changed action'
TEST_CONDITION='literal\nvalue\e[31m'
prompt_args_handle_add_security_rule_interactive add-security-rule >"$TEST_WORK/literal" <<< $'?\n\n'
grep -Fq -- "header:User-Agent contains $TEST_CONDITION" "$TEST_WORK/literal" || fail_test 'Confirmation interpreted literal backslash escapes in condition values'
[ "${PROMPT_ARGS_COLLECTED[5]}" = "$TEST_CONDITION" ] || fail_test 'Literal condition value changed in collected arguments'
[ -z "${CLI_PROMPT_LITERAL+x}" ] || fail_test 'Literal summary setting leaked to other prompts'
TEST_CONDITION=BadBot
TEST_ACTION=allow
PROMPT_ARGS_COLLECTED=()
prompt_args_handle_add_security_rule_interactive add-security-rule >"$TEST_WORK/allow" <<< ''
grep -Fq 'Rejection: none' "$TEST_WORK/allow" || fail_test 'Allow summary omitted its behavior'
PROMPT_ARGS_COLLECTED=()
if prompt_args_handle_add_security_rule_interactive add-security-rule >"$TEST_WORK/cancel" <<< q; then
  fail_test 'Cancel accepted the rule'
fi
[ "${#PROMPT_ARGS_COLLECTED[@]}" -eq 0 ] || fail_test 'Canceled rule retained executable arguments'
printf '[tests] interactive_walkthrough_review.sh: PASS\n'
