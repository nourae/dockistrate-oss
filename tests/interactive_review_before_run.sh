#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/arg_option_hint.sh
source "$ROOT_DIR/lib/cli/arg_option_hint.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/command_description.sh
source "$ROOT_DIR/lib/cli/command_description.sh"
# shellcheck source=../lib/cli/command_descriptions.sh
source "$ROOT_DIR/lib/cli/command_descriptions.sh"
# shellcheck source=../lib/cli/is_back_input.sh
source "$ROOT_DIR/lib/cli/is_back_input.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/review_command.sh
source "$ROOT_DIR/lib/cli/review_command.sh"
# shellcheck source=../lib/cli/prompt_args_for_command.sh
source "$ROOT_DIR/lib/cli/prompt_args_for_command.sh"

INTERACTIVE=true
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""
CURRENT_ARGS=()
PROMPT_ARGS_CONTEXT=()

READ_QUEUE=()
READ_CURSOR=0
CHOICE_QUEUE=()
CHOICE_CURSOR=0
LAST_CHOICE_PROMPT=""

function reset_review_prompt_test() {
  PROMPT_ARGS_COLLECTED=()
  SELECTED_ARGS=()
  SELECTED_CMD=""
  CURRENT_ARGS=()
  PROMPT_ARGS_CONTEXT=()
  READ_QUEUE=()
  READ_CURSOR=0
  CHOICE_QUEUE=("$@")
  CHOICE_CURSOR=0
  LAST_CHOICE_PROMPT=""
}

function get_arg_spec() {
  local cmd="${1:-}"
  case "$cmd" in
  mutating-test)
    printf '%s' 'first,;second,'
    ;;
  status)
    printf '%s' ''
    ;;
  *)
    return 1
    ;;
  esac
}

function get_arg_choices() { :; }
function mark_current_option() { :; }
function cmd_requires_existing_backend() { return 1; }
function has_backends() { return 0; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function prompt_args_postprocess() { return 0; }
function prompt_args_compute_default() { printf '%s' "${3:-}"; }

function choose_option() {
  local __idx_var="${1:-}"
  LAST_CHOICE_PROMPT="${2:-}"
  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    echo "[Error] choose_option called unexpectedly or queue exhausted." >&2
    exit 1
  fi
  printf -v "$__idx_var" '%s' "${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  return 0
}

function read_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}" value=""
  value="$default"
  if [ "$READ_CURSOR" -lt "${#READ_QUEUE[@]}" ]; then
    value="${READ_QUEUE[$READ_CURSOR]}"
  fi
  READ_CURSOR=$((READ_CURSOR + 1))
  printf -v "$__var" '%s' "$value"
}

function read_multiline_with_editing() {
  read_with_editing "$@"
}

reset_review_prompt_test 0
READ_QUEUE=("one" "two")
if ! prompt_args_for_command mutating-test >/dev/null; then
  echo "[Error] Mutating command should run after choosing Run on the review screen." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "mutating-test" ] || [ "${SELECTED_ARGS[*]}" != "one two" ]; then
  echo "[Error] Mutating command selection mismatch after review." >&2
  exit 1
fi
if [ "$CHOICE_CURSOR" -ne 1 ] || [[ "$LAST_CHOICE_PROMPT" != *"Review command"* ]] || [[ "$LAST_CHOICE_PROMPT" != *"CLI equivalent:"* ]]; then
  echo "[Error] Mutating command should render exactly one review prompt with CLI equivalent details." >&2
  exit 1
fi

reset_review_prompt_test
if ! prompt_args_for_command status >/dev/null; then
  echo "[Error] Read-only command should bypass review and select normally." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "status" ] || [ "$CHOICE_CURSOR" -ne 0 ]; then
  echo "[Error] Read-only command should not call the review chooser." >&2
  exit 1
fi

reset_review_prompt_test 2
READ_QUEUE=("one" "two")
set +e
prompt_args_for_command mutating-test >/dev/null
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "[Error] Cancel from the review screen should stop command selection." >&2
  exit 1
fi
if [ -n "${SELECTED_CMD:-}" ] || [ "${#SELECTED_ARGS[@]}" -ne 0 ] || [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne 0 ]; then
  echo "[Error] Cancel should clear selected command, selected args, and collected args." >&2
  exit 1
fi

echo "[tests] interactive_review_before_run.sh: PASS"
