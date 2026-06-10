#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/format_command_display.sh
source "$ROOT_DIR/lib/cli/format_command_display.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/command_description.sh
source "$ROOT_DIR/lib/cli/command_description.sh"
# shellcheck source=../lib/cli/command_descriptions.sh
source "$ROOT_DIR/lib/cli/command_descriptions.sh"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
# shellcheck source=../lib/cli/render_interactive.sh
source "$ROOT_DIR/lib/cli/render_interactive.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/choose_command_with_filter.sh
source "$ROOT_DIR/lib/cli/choose_command_with_filter.sh"

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

KEY_QUEUE=()
KEY_CURSOR=0
ESCAPE_QUEUE=()
ESCAPE_CURSOR=0
DOCKISTRATE_NO_CLEAR=true
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-context-help.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

function reset_keys() {
  KEY_QUEUE=("$@")
  KEY_CURSOR=0
  ESCAPE_QUEUE=()
  ESCAPE_CURSOR=0
}

function cli_read_keypress() {
  local __out_var="${1:-}"
  if [ "$KEY_CURSOR" -ge "${#KEY_QUEUE[@]}" ]; then
    printf -v "$__out_var" '%s' ""
    return 1
  fi
  printf -v "$__out_var" '%s' "${KEY_QUEUE[$KEY_CURSOR]}"
  KEY_CURSOR=$((KEY_CURSOR + 1))
  return 0
}

function cli_read_escape_sequence() {
  local __out_var="${1:-}"
  if [ "$ESCAPE_CURSOR" -ge "${#ESCAPE_QUEUE[@]}" ]; then
    printf -v "$__out_var" '%s' ""
    return 1
  fi
  printf -v "$__out_var" '%s' "${ESCAPE_QUEUE[$ESCAPE_CURSOR]}"
  ESCAPE_CURSOR=$((ESCAPE_CURSOR + 1))
  return 0
}

function clear() { :; }

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_contains() {
  local label="${1:-}" needle="${2:-}" haystack="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${label}: missing '${needle}'"
  fi
}

for fn in cli_interactive_help_for_context cli_show_interactive_help; do
  declare -F "$fn" >/dev/null 2>&1 || fail "missing function ${fn}"
done

idx=""
reset_keys "?" "x" $'\e' "" "2"
ESCAPE_QUEUE=("[A")
CLI_INTERACTIVE_CONTEXT=home
choose_option idx "Home menu" "one" "two" >"${tmp_dir}/home.out"
home_output="$(cat "${tmp_dir}/home.out")"
[ "$idx" = "1" ] || fail "choose_option should still select option 2 after help"
[ "$ESCAPE_CURSOR" -eq 1 ] || fail "help should drain arrow-key escape sequence before returning"
assert_contains "home help" "Home shows the operator dashboard" "$home_output"
assert_contains "home help footer" "Enter return" "$home_output"

idx=""
reset_keys "?" "" "1"
CLI_INTERACTIVE_CONTEXT=review-before-run
choose_option idx "Review command" "Run" "Edit previous answers" "Cancel" >"${tmp_dir}/review.out"
review_output="$(cat "${tmp_dir}/review.out")"
[ "$idx" = "0" ] || fail "review menu should still accept numeric selection after help"
assert_contains "review help" "Review shows the command" "$review_output"

filter="prox"
choice=""
reset_keys "?" "" ""
choose_command_with_filter choice filter "Command prompt:" "tail-proxy-logs" "status" >"${tmp_dir}/command.out"
command_output="$(cat "${tmp_dir}/command.out")"
[ "$choice" = "tail-proxy-logs" ] || fail "filtered command help flow selected '${choice}'"
[ "$filter" = "prox" ] || fail "command filter should remain unchanged after help"
assert_contains "command help search text" "Search commands with / or S" "$command_output"

global_filter="certificate"
global_choice=""
reset_keys "?" "" ""
choose_global_command_with_filter global_choice global_filter "Search all commands:" >"${tmp_dir}/global.out"
global_output="$(cat "${tmp_dir}/global.out")"
[ -n "$global_choice" ] || fail "global search should select a command after help"
[ "$global_filter" = "certificate" ] || fail "global filter should remain unchanged after help"
assert_contains "global help" "Global search lists commands" "$global_output"

idx=""
reset_keys "?" "" "1"
CLI_INTERACTIVE_CONTEXT=generic-choice
DOCKISTRATE_NO_CLEAR=true choose_option idx "No clear help" "one" "two" >"${tmp_dir}/no-clear.out"
no_clear_output="$(cat "${tmp_dir}/no-clear.out")"
[ "$idx" = "0" ] || fail "no-clear help flow should still select first item"
assert_contains "no-clear help content" "Use Up/Down or number keys" "$no_clear_output"

echo "[tests] interactive_contextual_help.sh: PASS"
