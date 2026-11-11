#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/utils/fs.sh
source "$ROOT_DIR/lib/utils/fs.sh"
function fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function require_valid_var_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function cli_clear_screen() { :; }
function cli_render_header() { :; }
function cli_render_footer() { :; }
function cli_read_escape_sequence() { return 1; }
function cli_read_keypress() {
  [ "$INPUT_KEY" != eof ] || return 1
  printf -v "$1" '%s' "$INPUT_KEY"
}

INPUT_KEY=''
CLI_CHOICE_INITIAL_INDEX=1
choose_option result Prompt first second >/dev/null
[ "$result" = 1 ] || fail 'Enter ignored the initial index'
[ -z "$CLI_CHOICE_CANCEL_REASON" ] || fail 'Successful choice retained a cancellation reason'
# These shell-looking characters are deliberately literal input.
# shellcheck disable=SC2016
for CLI_CHOICE_INITIAL_INDEX in '' -1 99 invalid '$(false)' 999999999999999999999; do
  choose_option result Prompt first second >/dev/null
  [ "$result" = 0 ] || fail 'Invalid initial index changed the first-option default'
done
unset CLI_CHOICE_INITIAL_INDEX
for INPUT_KEY in q Q $'\e' eof; do
  result=stale
  status=0
  choose_option result Prompt first second >/dev/null || status=$?
  [ "$status" = 1 ] && [ -z "$result" ] || fail 'Cancellation changed the public return contract'
  if [ "$INPUT_KEY" = eof ]; then expected=eof; else expected=back; fi
  [ "$CLI_CHOICE_CANCEL_REASON" = "$expected" ] || fail 'Cancellation reason does not distinguish Back from EOF'
done
INPUT_KEY=''
choose_option result Prompt first second >/dev/null
[ "$result" = 0 ] && [ -z "$CLI_CHOICE_CANCEL_REASON" ] || fail 'Cancellation reason leaked into next choice'

value=""
read_with_editing Prompt value fallback </dev/null
[ "$value" = fallback ] && [ "$READ_WITH_EDITING_CANCEL_REASON" = eof ] || fail 'Text EOF lost compatibility default or reason'
read_with_editing Prompt value fallback <<<''
[ "$value" = fallback ] && [ -z "$READ_WITH_EDITING_CANCEL_REASON" ] || fail 'Enter was confused with EOF'
read_with_editing Prompt value fallback < <(printf partial)
[ "$value" = partial ] && [ "$READ_WITH_EDITING_CANCEL_REASON" = eof ] || fail 'Text EOF lost partial input'
read_multiline_with_editing Prompt value fallback </dev/null
[ "$value" = fallback ] && [ "$READ_WITH_EDITING_CANCEL_REASON" = eof ] || fail 'Multiline EOF lost compatibility default or reason'
read_multiline_with_editing Prompt value < <(printf 'first\nlast')
[ "$value" = $'first\nlast' ] && [ "$READ_WITH_EDITING_CANCEL_REASON" = eof ] || fail 'Multiline EOF lost final unterminated line'
read_multiline_with_editing Prompt value fallback <<<''
[ "$value" = fallback ] && [ -z "$READ_WITH_EDITING_CANCEL_REASON" ] || fail 'Multiline blank terminator was confused with EOF'
printf '[tests] interactive_input_contract.sh: PASS\n'
