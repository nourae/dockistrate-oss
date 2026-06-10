#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"
# shellcheck source=../lib/cli/get_arg_spec.sh
source "$ROOT_DIR/lib/cli/get_arg_spec.sh"
# shellcheck source=../lib/cli/prompt_args_handlers_postprocess.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_postprocess.sh"
# shellcheck source=../lib/cli/prompt_args_for_command.sh
source "$ROOT_DIR/lib/cli/prompt_args_for_command.sh"

INTERACTIVE=true
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""
CURRENT_ARGS=()
PROMPT_ARGS_CONTEXT=()

CHOICE_CURSOR=0
CHOICE_QUEUE=(0 0 0 0 0 0 2 0 0 2)
ALT_SVC_MANUAL_COUNT=0

function get_arg_choices() {
  local cmd="${1:-}" arg="${2:-}"
  case "$arg" in
  domain)
    printf '%s\n' "$(csv_join_row "interactive-alt-svc.test" "interactive-alt-svc.test")"
    ;;
  container_port)
    printf '%s\n' "7000"
    ;;
  protocol)
    printf '%s\n' "$(csv_join_row "https" "HTTPS")"
    ;;
  cert_path)
    printf '%s\n' "$(csv_join_row "none" "none")"
    ;;
  ws)
    printf '%s\n' "$(csv_join_row "no" "no")"
    ;;
  port)
    printf '%s\n' "18443"
    ;;
  http3)
    __arg_choices_http3
    ;;
  alt_svc)
    __arg_choices_alt_svc
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
  *"Alt-Svc"*)
    if [ "$ALT_SVC_MANUAL_COUNT" -eq 0 ]; then
      value="h3=:18443;ma=120"
    else
      value="h3=:18443;ma=240"
    fi
    ALT_SVC_MANUAL_COUNT=$((ALT_SVC_MANUAL_COUNT + 1))
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

output_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_prompt_alt_svc_manual.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

set +e
prompt_args_for_command add-port >"$output_file" 2>&1
status=$?
set -e
output="$(cat "$output_file")"

if [ "$status" -ne 0 ]; then
  echo "[Error] prompt_args_for_command add-port failed unexpectedly while collecting manual alt_svc." >&2
  echo "$output" >&2
  exit 1
fi

if [ "$SELECTED_CMD" != "add-port" ]; then
  echo "[Error] Expected SELECTED_CMD=add-port, got '${SELECTED_CMD:-<unset>}'." >&2
  exit 1
fi

expected_add_port_args=(
  "interactive-alt-svc.test" "18443" "7000" "https" "none" "no"
  "--http3" "on" "--alt-svc" "h3=:18443;ma=120"
)
if [ "${#SELECTED_ARGS[@]}" -ne "${#expected_add_port_args[@]}" ]; then
  echo "[Error] Expected ${#expected_add_port_args[@]} add-port args, got ${#SELECTED_ARGS[@]}." >&2
  exit 1
fi

idx=0
for idx in "${!expected_add_port_args[@]}"; do
  if [ "${SELECTED_ARGS[$idx]}" != "${expected_add_port_args[$idx]}" ]; then
    echo "[Error] add-port selected arg ${idx} mismatch: expected '${expected_add_port_args[$idx]}', got '${SELECTED_ARGS[$idx]}'." >&2
    exit 1
  fi
done

set +e
prompt_args_for_command set-port-http3 >"$output_file" 2>&1
status=$?
set -e
output="$(cat "$output_file")"

if [ "$status" -ne 0 ]; then
  echo "[Error] prompt_args_for_command set-port-http3 failed unexpectedly while collecting manual alt_svc." >&2
  echo "$output" >&2
  exit 1
fi

if [ "$SELECTED_CMD" != "set-port-http3" ]; then
  echo "[Error] Expected SELECTED_CMD=set-port-http3, got '${SELECTED_CMD:-<unset>}'." >&2
  exit 1
fi

expected_set_port_http3_args=("18443" "on" "h3=:18443;ma=240")
if [ "${#SELECTED_ARGS[@]}" -ne "${#expected_set_port_http3_args[@]}" ]; then
  echo "[Error] Expected ${#expected_set_port_http3_args[@]} set-port-http3 args, got ${#SELECTED_ARGS[@]}." >&2
  exit 1
fi

for idx in "${!expected_set_port_http3_args[@]}"; do
  if [ "${SELECTED_ARGS[$idx]}" != "${expected_set_port_http3_args[$idx]}" ]; then
    echo "[Error] set-port-http3 selected arg ${idx} mismatch: expected '${expected_set_port_http3_args[$idx]}', got '${SELECTED_ARGS[$idx]}'." >&2
    exit 1
  fi
done

echo "prompt_args alt_svc manual collection guard passed."
