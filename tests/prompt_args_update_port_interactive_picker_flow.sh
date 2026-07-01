#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"
# shellcheck source=../lib/cli/arg_choices_images.sh
source "$ROOT_DIR/lib/cli/arg_choices_images.sh"
# shellcheck source=../lib/cli/arg_choices_protocols.sh
source "$ROOT_DIR/lib/cli/arg_choices_protocols.sh"
# shellcheck source=../lib/cli/get_arg_choices.sh
source "$ROOT_DIR/lib/cli/get_arg_choices.sh"
# shellcheck source=../lib/cli/get_arg_spec.sh
source "$ROOT_DIR/lib/cli/get_arg_spec.sh"
# shellcheck source=../lib/cli/prompt_args_handlers_postprocess.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_postprocess.sh"
# shellcheck source=../lib/cli/collect_update_port_interactive.sh
source "$ROOT_DIR/lib/cli/collect_update_port_interactive.sh"
# shellcheck source=../lib/cli/review_command.sh
source "$ROOT_DIR/lib/cli/review_command.sh"
# shellcheck source=../lib/cli/prompt_args_for_command.sh
source "$ROOT_DIR/lib/cli/prompt_args_for_command.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_update_port_picker.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

INTERACTIVE=true
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""
CURRENT_ARGS=()
PROMPT_ARGS_CONTEXT=()

BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
CERTS_DIR="${tmp_dir}/certs"
NGINX_HTTP_CONF_DIR="${tmp_dir}/nginx"
mkdir -p "$CERTS_DIR" "$NGINX_HTTP_CONF_DIR"
cat >"$BACKEND_PORTS_FILE" <<EOF_PORTS
${STATE_BACKEND_PORTS_HEADER}
backend,example.test,172.30.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.test,,,,,80,8080,http,none,no,off,,off,auto,,,,,,
port,example.test,,,,,8443,9443,https,none,no,off,,off,auto,,,,,,
EOF_PORTS

PROMPT_LOG="${tmp_dir}/prompts.log"
CHOICE_CURSOR=0
CHOICE_QUEUE=(0 0 0 0 2 0 0 0 0 0)

function command_alias() { printf '%s\n' "${1:-}"; }
function command_description() { printf '%s\n' "Update an existing port mapping"; }
function mark_current_option() { :; }
function prompt_args_compute_default() { printf '%s' "${3:-}"; }
function arg_option_hint() { :; }
function is_back_input() { return 1; }
function cmd_requires_existing_backend() { return 0; }
function has_backends() { return 0; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function get_backend_image() { return 1; }
function get_backend_ws_flag() { printf '%s\n' "no"; }

function choose_option() {
  local __idx_var="${1:-}" prompt="${2:-}"
  local selected_idx="${CHOICE_QUEUE[$CHOICE_CURSOR]:-0}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf '%s\n' "$prompt" >>"$PROMPT_LOG"
  printf -v "$__idx_var" '%s' "$selected_idx"
  return 0
}

function choose_option_with_context_status() {
  local __status_var="${1:-}" __idx_var="${2:-}" _context="${3:-}" prompt="${4:-}" choose_status=0
  shift 4
  if choose_option "$__idx_var" "$prompt" "$@"; then
    choose_status=0
  else
    choose_status=$?
  fi
  printf -v "$__status_var" '%s' "$choose_status"
  return 0
}

function read_with_editing() {
  local prompt="${1:-}" __var="${2:-}" default="${3:-}"
  case "$prompt" in
  *"Protocol"* | *"Certificate"* | *"WebSocket"* | *"HTTP3"* | *"HTTP/3"*)
    echo "[Error] update-port should not raw-prompt for enumerable routing options: $prompt" >&2
    exit 1
    ;;
  esac
  printf -v "$__var" '%s' "$default"
}

function read_multiline_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}"
  printf -v "$__var" '%s' "$default"
}

output_file="${tmp_dir}/output.txt"
set +e
prompt_args_for_command update-port >"$output_file" 2>&1
status=$?
set -e
output="$(cat "$output_file")"

if [ "$status" -ne 0 ]; then
  echo "[Error] prompt_args_for_command update-port failed." >&2
  echo "$output" >&2
  exit 1
fi

if [ "$SELECTED_CMD" != "update-port" ]; then
  echo "[Error] Expected SELECTED_CMD=update-port, got '${SELECTED_CMD:-<unset>}'." >&2
  exit 1
fi

expected=(
  example.test 80 --nginx-port 80 --container-port 8080 --protocol https
  --cert none --ws no --http3 off --alt-svc auto
)
if [ "${#SELECTED_ARGS[@]}" -ne "${#expected[@]}" ]; then
  echo "[Error] Expected ${#expected[@]} selected args, got ${#SELECTED_ARGS[@]}." >&2
  printf 'Actual args: %s\n' "${SELECTED_ARGS[*]}" >&2
  exit 1
fi
for idx in "${!expected[@]}"; do
  if [ "${SELECTED_ARGS[$idx]}" != "${expected[$idx]}" ]; then
    echo "[Error] update-port selected arg ${idx} mismatch: expected '${expected[$idx]}', got '${SELECTED_ARGS[$idx]}'." >&2
    exit 1
  fi
done

port_prompt_line="$(grep -n '^Port mapping to update:' "$PROMPT_LOG" | cut -d: -f1 | head -n 1)"
review_prompt_line="$(grep -n '^Review command' "$PROMPT_LOG" | cut -d: -f1 | head -n 1)"
if [ -z "$port_prompt_line" ] || [ -z "$review_prompt_line" ] || [ "$port_prompt_line" -ge "$review_prompt_line" ]; then
  echo "[Error] update-port review should appear only after the port mapping is selected." >&2
  cat "$PROMPT_LOG" >&2
  exit 1
fi

if ! grep -Fq './dockistrate.sh update-port example.test 80 --nginx-port 80 --container-port 8080 --protocol https --cert none --ws no --http3 off --alt-svc auto' "$PROMPT_LOG"; then
  echo "[Error] update-port review should show the full flag-style CLI equivalent." >&2
  cat "$PROMPT_LOG" >&2
  exit 1
fi
if ! grep -Fq 'New listen port: 80' "$PROMPT_LOG" || ! grep -Fq 'Certificate: none' "$PROMPT_LOG"; then
  echo "[Error] update-port review should render semantic argument labels." >&2
  cat "$PROMPT_LOG" >&2
  exit 1
fi

echo "prompt args update-port interactive picker flow checks passed."
