#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
DEFAULT_CALL_FILE=""
CHOICE_QUEUE=()
CHOICE_CURSOR=0

function reset_prompt_state() {
  PROMPT_ARGS_COLLECTED=()
  SELECTED_ARGS=()
  SELECTED_CMD=""
  CURRENT_ARGS=()
  PROMPT_ARGS_CONTEXT=()
  READ_QUEUE=("$@")
  READ_CURSOR=0
  READ_PROMPTS=()
  CHOICE_QUEUE=()
  CHOICE_CURSOR=0
  if [ -n "${DEFAULT_CALL_FILE:-}" ]; then
    : >"$DEFAULT_CALL_FILE"
  fi
}

function get_arg_spec() {
  local cmd="${1:-}"
  case "$cmd" in
  backtrack-test)
    printf '%s' 'first,;second,;third,'
    ;;
  choices-test)
    printf '%s' 'first,;second,;third,'
    ;;
  add-port)
    printf '%s' 'domain,;nginx_port,;container_port,;protocol,http;cert_path,none;ws,no;http3,off;alt_svc,auto;tail,'
    ;;
  *)
    return 1
    ;;
  esac
}

# choose_option mock: reads from CHOICE_QUEUE.
# Each element is either "fail" (simulate user pressing Ctrl-C / esc) or a
# numeric index to return.
function choose_option() {
  local __idx_var="${1:-}"
  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    echo "[Error] choose_option called but CHOICE_QUEUE exhausted (cursor=${CHOICE_CURSOR}, size=${#CHOICE_QUEUE[@]})." >&2
    exit 1
  fi
  local action="${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  if [ "$action" = "fail" ]; then
    return 1
  fi
  printf -v "$__idx_var" '%s' "$action"
  return 0
}

function get_arg_choices() {
  local cmd="${1:-}" name="${2:-}"
  if [[ "$cmd" == "choices-test" && "$name" == "second" ]]; then
    printf '%s\n' "choice-A"
    printf '%s\n' "choice-B"
  fi
}
function mark_current_option() { :; }
function cmd_requires_existing_backend() { return 1; }
function has_backends() { return 0; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function prompt_args_postprocess() { return 0; }

function prompt_args_compute_default() {
  local cmd="${1:-}" name="${2:-}" default="${3:-}"
  if [ -n "${DEFAULT_CALL_FILE:-}" ]; then
    printf '%s\n' "${cmd}:${name}:${PROMPT_ARGS_CONTEXT[*]:-}" >>"$DEFAULT_CALL_FILE"
  fi
  printf '%s' "$default"
}

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
  local idx=0
  if [ "${#SELECTED_ARGS[@]}" -ne "${#expected[@]}" ]; then
    echo "[Error] ${label}: expected ${#expected[@]} args, got ${#SELECTED_ARGS[@]}." >&2
    printf 'Expected: %s\n' "${expected[*]}" >&2
    printf 'Actual: %s\n' "${SELECTED_ARGS[*]:-}" >&2
    exit 1
  fi
  for idx in "${!expected[@]}"; do
    if [ "${SELECTED_ARGS[$idx]}" != "${expected[$idx]}" ]; then
      echo "[Error] ${label}: arg ${idx} mismatch: expected '${expected[$idx]}', got '${SELECTED_ARGS[$idx]}'." >&2
      exit 1
    fi
  done
}

output_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_prompt_backtracking.XXXXXX")"
DEFAULT_CALL_FILE="$(mktemp "${TMPDIR:-/tmp}/dockistrate_prompt_default_calls.XXXXXX")"
trap 'rm -f "$output_file" "$DEFAULT_CALL_FILE"' EXIT

reset_prompt_state "one" "two" "back" "two-edited" "three"
if ! prompt_args_for_command backtrack-test >"$output_file" 2>&1; then
  echo "[Error] backtrack-test failed while backtracking from third argument." >&2
  cat "$output_file" >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "backtrack-test" ]; then
  echo "[Error] Expected SELECTED_CMD=backtrack-test, got '${SELECTED_CMD:-<unset>}'." >&2
  exit 1
fi
assert_selected_args "backtrack-test" "one" "two-edited" "three"

second_prompt_count=0
for prompt in "${READ_PROMPTS[@]}"; do
  case "$prompt" in
  second*) second_prompt_count=$((second_prompt_count + 1)) ;;
  esac
done
if [ "$second_prompt_count" -ne 2 ]; then
  echo "[Error] Expected second argument to be prompted twice after Back, got ${second_prompt_count}." >&2
  printf '%s\n' "${READ_PROMPTS[@]}" >&2
  exit 1
fi

reset_prompt_state "one" "__DOCKISTRATE_PROMPT_ARGS_BACKTRACK__" "three"
if ! prompt_args_for_command backtrack-test >"$output_file" 2>&1; then
  echo "[Error] backtrack-test failed when collecting a literal sentinel-like value." >&2
  cat "$output_file" >&2
  exit 1
fi
assert_selected_args "literal sentinel value" \
  "one" "__DOCKISTRATE_PROMPT_ARGS_BACKTRACK__" "three"

reset_prompt_state "back"
set +e
prompt_args_for_command backtrack-test >"$output_file" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "[Error] Back on first argument should return to the command menu." >&2
  exit 1
fi
if [ -n "${SELECTED_CMD:-}" ] || [ "${#SELECTED_ARGS[@]}" -ne 0 ] || [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne 0 ]; then
  echo "[Error] Back on first argument should clear selected command and args." >&2
  exit 1
fi

reset_prompt_state "example.com" "80" "8080" "tcp" "back" "http" "no" "tail"
if ! prompt_args_for_command add-port >"$output_file" 2>&1; then
  echo "[Error] add-port failed while backtracking across skipped cert/ws prompts." >&2
  cat "$output_file" >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "add-port" ]; then
  echo "[Error] Expected SELECTED_CMD=add-port, got '${SELECTED_CMD:-<unset>}'." >&2
  exit 1
fi
assert_selected_args "add-port skip backtracking" \
  "example.com" "80" "8080" "http" "none" "no" "off" "auto" "tail"

protocol_default_count=0
while IFS= read -r call; do
  case "$call" in
  add-port:protocol:example.com\ 80\ 8080) protocol_default_count=$((protocol_default_count + 1)) ;;
  esac
done <"$DEFAULT_CALL_FILE"
if [ "$protocol_default_count" -ne 2 ]; then
  echo "[Error] Expected add-port protocol defaults/context to be recomputed after Back, got ${protocol_default_count}." >&2
  cat "$DEFAULT_CALL_FILE" >&2
  exit 1
fi

reset_prompt_state "udp.example.com" "1053" "53" "udp" "tail"
if ! prompt_args_for_command add-port >"$output_file" 2>&1; then
  echo "[Error] add-port failed while skipping HTTP/3 prompts for UDP." >&2
  cat "$output_file" >&2
  exit 1
fi
assert_selected_args "add-port udp skips http3 prompts" \
  "udp.example.com" "1053" "53" "udp" "none" "no" "off" "auto" "tail"
for prompt in "${READ_PROMPTS[@]}"; do
  case "$prompt" in
  *"HTTP/3"* | *"Alt-Svc"*)
    echo "[Error] add-port UDP should not prompt for HTTP/3 or Alt-Svc, saw: $prompt" >&2
    exit 1
    ;;
  esac
done

# Choices-based backtracking: choose_option fails on first pass → back to first arg.
# CHOICE_QUEUE: "fail" on first second-arg prompt, 0 (choice-A) on the re-prompt.
reset_prompt_state "val1" "val1-updated" "val3"
CHOICE_QUEUE=("fail" "0")
if ! prompt_args_for_command choices-test >"$output_file" 2>&1; then
  echo "[Error] choices-test failed during choices-based backtracking." >&2
  cat "$output_file" >&2
  exit 1
fi
assert_selected_args "choices-based backtrack" "val1-updated" "choice-A" "val3"

echo "[tests] prompt_args_generic_backtracking.sh: PASS"
