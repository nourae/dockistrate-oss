#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/prompt_args_for_command.sh
source "$ROOT_DIR/lib/cli/prompt_args_for_command.sh"

INTERACTIVE=true
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""
CURRENT_ARGS=()
PROMPT_ARGS_CONTEXT=()

CHOICE_CURSOR=0
CHOICE_QUEUE=(0 0 1 0 1)

function get_arg_spec() {
  local cmd="${1:-}"
  if [ "$cmd" != "add-port" ]; then
    return 1
  fi
  printf '%s' 'domain,;nginx_port,;container_port,;protocol,http;cert_path,none;ws,no'
}

function get_arg_choices() {
  local cmd="${1:-}" arg="${2:-}"
  [ "$cmd" = "add-port" ] || return 0
  case "$arg" in
  domain)
    printf '%s\n' "$(csv_join_row "e2e-http.example.com" "e2e-http.example.com")"
    ;;
  container_port)
    printf '%s\n' "80"
    ;;
  protocol)
    printf '%s\n' "$(csv_join_row "http" "HTTP (current)")"
    printf '%s\n' "$(csv_join_row "https" "HTTPS")"
    printf '%s\n' "$(csv_join_row "tcp" "TCP")"
    ;;
  cert_path)
    printf '%s\n' "$(csv_join_row "none" "none (current)")"
    ;;
  ws)
    printf '%s\n' "$(csv_join_row "yes" "yes")"
    printf '%s\n' "$(csv_join_row "no" "no (current)")"
    ;;
  esac
}

function choose_option() {
  local __idx_var="${1:-}"
  local selected_idx="${CHOICE_QUEUE[$CHOICE_CURSOR]:-0}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf -v "$__idx_var" '%s' "$selected_idx"
  return 0
}

function read_with_editing() {
  local prompt="${1:-}" __var="${2:-}" default="${3:-}"
  local value="$default"
  case "$prompt" in
  *"Listen port"*)
    value="18443"
    ;;
  esac
  printf -v "$__var" '%s' "$value"
}

function read_multiline_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}"
  printf -v "$__var" '%s' "$default"
}

function prompt_args_compute_default() {
  local _cmd="${1:-}" _name="${2:-}" default="${3:-}"
  printf '%s' "$default"
}

function arg_option_hint() { :; }
function mark_current_option() { :; }
function is_back_input() { return 1; }
function cmd_requires_existing_backend() { return 1; }
function has_backends() { return 0; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function prompt_args_postprocess() { return 0; }

output_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_prompt_args_add_port.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

set +e
prompt_args_for_command add-port >"$output_file" 2>&1
status=$?
set -e
output="$(cat "$output_file")"

if [ "$status" -ne 0 ]; then
  echo "[Error] prompt_args_for_command add-port failed unexpectedly under interactive no-choice fallback." >&2
  echo "$output" >&2
  exit 1
fi

if grep -Fq "prompt_args_handle_nginx_directives: command not found" <<<"$output"; then
  echo "[Error] prompt_args_for_command add-port emitted missing-handler noise." >&2
  echo "$output" >&2
  exit 1
fi

if [ "$SELECTED_CMD" != "add-port" ]; then
  echo "[Error] Expected SELECTED_CMD=add-port, got '${SELECTED_CMD:-<unset>}'." >&2
  exit 1
fi

expected=("e2e-http.example.com" "18443" "80" "https" "none" "no")
if [ "${#SELECTED_ARGS[@]}" -ne "${#expected[@]}" ]; then
  echo "[Error] Expected ${#expected[@]} selected args, got ${#SELECTED_ARGS[@]}." >&2
  exit 1
fi

idx=0
for idx in "${!expected[@]}"; do
  if [ "${SELECTED_ARGS[$idx]}" != "${expected[$idx]}" ]; then
    echo "[Error] add-port selected arg ${idx} mismatch: expected '${expected[$idx]}', got '${SELECTED_ARGS[$idx]}'." >&2
    exit 1
  fi
done

echo "prompt_args add-port interactive no-choice fallback guard passed."
