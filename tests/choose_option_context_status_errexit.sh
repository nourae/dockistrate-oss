#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function cli_clear_screen() { :; }
function cli_render_header() { :; }
function cli_render_footer() { :; }
function cli_read_escape_sequence() { return 1; }
function cli_read_keypress() {
  local __out_var="${1:-}" __key=""
  if ! IFS= read -rsn1 __key; then
    return 1
  fi
  printf -v "$__out_var" '%s' "$__key"
}

idx="kept"
choose_status=99
CLI_INTERACTIVE_CONTEXT="outer-context"
choose_option_with_context_status choose_status idx "home" "Prompt" "one" "Quit" <<<"q"

if [ "$choose_status" -ne 1 ]; then
  echo "[Error] choose_option_with_context_status should capture Q cancellation status 1." >&2
  exit 1
fi
if [ -n "$idx" ]; then
  echo "[Error] choose_option_with_context_status should preserve choose_option cancellation output." >&2
  exit 1
fi
if [ "${CLI_INTERACTIVE_CONTEXT:-}" != "outer-context" ]; then
  echo "[Error] choose_option_with_context_status should restore the previous context." >&2
  exit 1
fi

unset CLI_INTERACTIVE_CONTEXT
idx="kept"
choose_status=99
choose_option_with_context_status choose_status idx "home" "Prompt" "one" "Quit" <<<"q"

if [ "$choose_status" -ne 1 ]; then
  echo "[Error] choose_option_with_context_status should capture Q cancellation without a previous context." >&2
  exit 1
fi
if [ "${CLI_INTERACTIVE_CONTEXT+x}" = "x" ]; then
  echo "[Error] choose_option_with_context_status should leave an unset previous context unset." >&2
  exit 1
fi

echo "[tests] choose_option_context_status_errexit.sh: PASS"
