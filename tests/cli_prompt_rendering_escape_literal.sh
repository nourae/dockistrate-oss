#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/format_command_display.sh
source "$ROOT_DIR/lib/cli/format_command_display.sh"
# shellcheck source=../lib/cli/render_interactive.sh
source "$ROOT_DIR/lib/cli/render_interactive.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
# shellcheck source=../lib/cli/choose_command_with_filter.sh
source "$ROOT_DIR/lib/cli/choose_command_with_filter.sh"

function require_valid_var_name() { return 0; }
function clear() { :; }
function cli_read_keypress() {
  local __out_var="${1:-}"
  printf -v "$__out_var" '%s' ""
  return 0
}
function command_alias() { printf '%s' "$1"; }
function command_description() { printf '%s' "description"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

function assert_prompt_rendered_safely() {
  local output="$1" helper_name="$2"

  if LC_ALL=C printf '%s' "$output" | LC_ALL=C grep -Fq $'\x1b'; then
    echo "[Error] ${helper_name} rendered terminal escape bytes from prompt content." >&2
    exit 1
  fi

  if ! printf '%s\n' "$output" | grep -Fxq 'line1'; then
    echo "[Error] ${helper_name} did not render literal \\n as a newline." >&2
    exit 1
  fi

  if ! printf '%s\n' "$output" | grep -Fq 'line2\e[31mRED'; then
    echo "[Error] ${helper_name} should preserve non-newline backslash escapes literally." >&2
    exit 1
  fi
}

prompt='line1\nline2\e[31mRED'

chosen_idx=""
choose_option_output_file="$TMP_DIR/choose_option.out"
choose_option chosen_idx "$prompt" "one" "two" >"$choose_option_output_file"
choose_option_output="$(cat "$choose_option_output_file")"
assert_prompt_rendered_safely "$choose_option_output" "choose_option"
if [ "$chosen_idx" != "0" ]; then
  echo "[Error] choose_option should still select the first option on Enter." >&2
  exit 1
fi

filter_state=""
chosen_command=""
choose_command_output_file="$TMP_DIR/choose_command_with_filter.out"
choose_command_with_filter chosen_command filter_state "$prompt" "status" >"$choose_command_output_file"
choose_command_output="$(cat "$choose_command_output_file")"
assert_prompt_rendered_safely "$choose_command_output" "choose_command_with_filter"
if [ "$chosen_command" != "status" ]; then
  echo "[Error] choose_command_with_filter should still select the first command on Enter." >&2
  exit 1
fi

global_filter_state=""
global_chosen_command=""
choose_global_output_file="$TMP_DIR/choose_global_command_with_filter.out"
choose_global_command_with_filter global_chosen_command global_filter_state "$prompt" >"$choose_global_output_file"
choose_global_output="$(cat "$choose_global_output_file")"
assert_prompt_rendered_safely "$choose_global_output" "choose_global_command_with_filter"
if [ "$global_chosen_command" != "start-nginx" ]; then
  echo "[Error] choose_global_command_with_filter should still select the first global command on Enter." >&2
  exit 1
fi

echo "CLI prompt rendering escape literal safety checks passed."
