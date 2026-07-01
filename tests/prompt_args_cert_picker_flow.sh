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
# shellcheck source=../lib/cli/get_arg_choices.sh
source "$ROOT_DIR/lib/cli/get_arg_choices.sh"
# shellcheck source=../lib/cli/get_arg_spec.sh
source "$ROOT_DIR/lib/cli/get_arg_spec.sh"
# shellcheck source=../lib/cli/prompt_args_handlers_postprocess.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_postprocess.sh"
# shellcheck source=../lib/cli/review_command.sh
source "$ROOT_DIR/lib/cli/review_command.sh"
# shellcheck source=../lib/cli/prompt_args_for_command.sh
source "$ROOT_DIR/lib/cli/prompt_args_for_command.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_cert_picker_flow.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

INTERACTIVE=true
BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
CERTS_DIR="${tmp_dir}/certs"
NGINX_HTTP_CONF_DIR="${tmp_dir}/nginx"
mkdir -p "$CERTS_DIR/selfsigned/live/example.test_443" "$CERTS_DIR/selfsigned/live/example.test_8443" "$NGINX_HTTP_CONF_DIR"
printf 'dummy cert\n' >"$CERTS_DIR/selfsigned/live/example.test_443/fullchain.pem"
printf 'dummy cert\n' >"$CERTS_DIR/selfsigned/live/example.test_8443/fullchain.pem"
cat >"$BACKEND_PORTS_FILE" <<EOF_PORTS
${STATE_BACKEND_PORTS_HEADER}
backend,example.test,172.30.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.test,,,,,8443,9443,https,selfsigned/live/example.test_8443,no,off,,off,auto,,,,,,
EOF_PORTS

PROMPT_LOG="${tmp_dir}/prompts.log"
UPLOAD_PROMPT_COUNT=0
CHOICE_CURSOR=0
CHOICE_QUEUE=()

function reset_prompt_state() {
  PROMPT_ARGS_COLLECTED=()
  SELECTED_ARGS=()
  SELECTED_CMD=""
  CURRENT_ARGS=()
  PROMPT_ARGS_CONTEXT=()
  : >"$PROMPT_LOG"
  CHOICE_CURSOR=0
  UPLOAD_PROMPT_COUNT=0
}

function command_alias() { printf '%s\n' "${1:-}"; }
function command_description() { printf '%s\n' "Certificate command"; }
function mark_current_option() { :; }
function prompt_args_compute_default() { printf '%s' "${3:-}"; }
function arg_option_hint() { :; }
function is_back_input() { return 1; }
function cmd_requires_existing_backend() { return 1; }
function has_backends() { return 0; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }

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
  local prompt="${1:-}" __var="${2:-}" default="${3:-}" value="$default"
  case "$prompt" in
  *"Fullchain path"*)
    value="${tmp_dir}/fullchain.pem"
    UPLOAD_PROMPT_COUNT=$((UPLOAD_PROMPT_COUNT + 1))
    ;;
  *"Private key path"*)
    value="${tmp_dir}/privkey.pem"
    UPLOAD_PROMPT_COUNT=$((UPLOAD_PROMPT_COUNT + 1))
    ;;
  *"Type YES"*)
    value="YES"
    ;;
  *"upload"*)
    echo "[Error] Unexpected upload prompt shape: $prompt" >&2
    exit 1
    ;;
  esac
  printf -v "$__var" '%s' "$value"
}

function read_multiline_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}"
  printf -v "$__var" '%s' "$default"
}

printf 'cert\n' >"${tmp_dir}/fullchain.pem"
printf 'key\n' >"${tmp_dir}/privkey.pem"

reset_prompt_state
CHOICE_QUEUE=(0 0 0 0)
if ! prompt_args_for_command add-cert >/dev/null 2>&1; then
  echo "[Error] add-cert self-signed picker flow failed." >&2
  exit 1
fi
expected_add=(example.test 443 selfsigned)
if [ "$SELECTED_CMD" != "add-cert" ] || [ "${SELECTED_ARGS[*]}" != "${expected_add[*]}" ]; then
  echo "[Error] add-cert self-signed selected args mismatch: ${SELECTED_CMD:-} ${SELECTED_ARGS[*]-}" >&2
  exit 1
fi
if [ "$UPLOAD_PROMPT_COUNT" -ne 0 ]; then
  echo "[Error] add-cert self-signed should not prompt for upload paths." >&2
  exit 1
fi
if ! grep -Fq 'Certificate type' "$PROMPT_LOG"; then
  echo "[Error] add-cert should prompt for certificate type before review." >&2
  cat "$PROMPT_LOG" >&2
  exit 1
fi

reset_prompt_state
CHOICE_QUEUE=(0 0 2 0)
if ! prompt_args_for_command replace-cert >/dev/null 2>&1; then
  echo "[Error] replace-cert upload picker flow failed." >&2
  exit 1
fi
expected_replace=(example.test 443 upload "${tmp_dir}/fullchain.pem" "${tmp_dir}/privkey.pem")
if [ "$SELECTED_CMD" != "replace-cert" ] || [ "${SELECTED_ARGS[*]}" != "${expected_replace[*]}" ]; then
  echo "[Error] replace-cert upload selected args mismatch: ${SELECTED_CMD:-} ${SELECTED_ARGS[*]-}" >&2
  exit 1
fi
if [ "$UPLOAD_PROMPT_COUNT" -ne 2 ]; then
  echo "[Error] replace-cert upload should prompt for fullchain and private key only after upload is selected." >&2
  exit 1
fi

reset_prompt_state
CHOICE_QUEUE=(0 1 0)
if ! prompt_args_for_command remove-cert >/dev/null 2>&1; then
  echo "[Error] remove-cert picker flow failed." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "remove-cert" ] || [ "${SELECTED_ARGS[0]:-}" != "example.test" ] || [ "${SELECTED_ARGS[1]:-}" != "8443" ]; then
  echo "[Error] remove-cert should collect domain and selected certificate suffix, got: ${SELECTED_ARGS[*]-}" >&2
  exit 1
fi
if ! grep -Fq 'Certificate port suffix' "$PROMPT_LOG"; then
  echo "[Error] remove-cert should use the certificate suffix picker." >&2
  cat "$PROMPT_LOG" >&2
  exit 1
fi

echo "prompt args cert picker flow checks passed."
