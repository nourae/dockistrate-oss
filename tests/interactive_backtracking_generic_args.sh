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
# shellcheck source=../lib/cli/is_back_input.sh
source "$ROOT_DIR/lib/cli/is_back_input.sh"
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
READ_PROMPTS=()

function reset_backtracking_test() {
  PROMPT_ARGS_COLLECTED=()
  SELECTED_ARGS=()
  SELECTED_CMD=""
  CURRENT_ARGS=()
  PROMPT_ARGS_CONTEXT=()
  READ_QUEUE=("$@")
  READ_CURSOR=0
  READ_PROMPTS=()
}

function get_arg_spec() {
  local cmd="${1:-}"
  case "$cmd" in
  backtrack-test)
    printf '%s' 'first,;second,;third,'
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

function read_with_editing() {
  local prompt="${1:-}" __var="${2:-}" default="${3:-}" value
  READ_PROMPTS+=("$prompt")
  if [ "$READ_CURSOR" -lt "${#READ_QUEUE[@]}" ]; then
    value="${READ_QUEUE[$READ_CURSOR]}"
  else
    value="$default"
  fi
  READ_CURSOR=$((READ_CURSOR + 1))
  printf -v "$__var" '%s' "$value"
}

function read_multiline_with_editing() {
  read_with_editing "$@"
}

function assert_selected_args() {
  local label="${1:-selection}"
  shift
  local expected=("$@")
  local idx
  if [ "${#SELECTED_ARGS[@]}" -ne "${#expected[@]}" ]; then
    echo "[Error] ${label}: expected ${#expected[@]} args, got ${#SELECTED_ARGS[@]}." >&2
    exit 1
  fi
  for idx in "${!expected[@]}"; do
    if [ "${SELECTED_ARGS[$idx]}" != "${expected[$idx]}" ]; then
      echo "[Error] ${label}: arg ${idx} mismatch: expected '${expected[$idx]}', got '${SELECTED_ARGS[$idx]}'." >&2
      exit 1
    fi
  done
}

output_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_interactive_backtracking.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

reset_backtracking_test "one" "two" "back" "two-edited" "three"
if ! prompt_args_for_command backtrack-test >"$output_file" 2>&1; then
  echo "[Error] Back from a later generic argument should re-prompt the previous argument." >&2
  cat "$output_file" >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "backtrack-test" ]; then
  echo "[Error] Expected SELECTED_CMD=backtrack-test, got '${SELECTED_CMD:-<unset>}'." >&2
  exit 1
fi
assert_selected_args "generic argument backtracking" "one" "two-edited" "three"

second_prompt_count=0
for prompt in "${READ_PROMPTS[@]}"; do
  case "$prompt" in
  second*) second_prompt_count=$((second_prompt_count + 1)) ;;
  esac
done
if [ "$second_prompt_count" -ne 2 ]; then
  echo "[Error] Expected the second argument to be prompted twice, got ${second_prompt_count}." >&2
  exit 1
fi

reset_backtracking_test "back"
set +e
prompt_args_for_command backtrack-test >"$output_file" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "[Error] Back on the first argument should return to the command menu." >&2
  exit 1
fi
if [ -n "${SELECTED_CMD:-}" ] || [ "${#SELECTED_ARGS[@]}" -ne 0 ] || [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne 0 ]; then
  echo "[Error] Back on the first argument should clear selected command and args." >&2
  exit 1
fi

echo "[tests] interactive_backtracking_generic_args.sh: PASS"
