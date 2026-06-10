#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/security_rule_interactive_common.sh
source "$ROOT_DIR/lib/cli/security_rule_interactive_common.sh"

INTERACTIVE=true

function get_arg_choices() {
  local cmd="${1:-}" arg="${2:-}"
  if [ "$cmd" = "add-security-rule" ] && [ "$arg" = "mode" ]; then
    printf '%s\n' "and"
    return 0
  fi
  return 0
}

function _sr_prompt_choice() {
  local __var="${1:-}" prompt="${2:-}" opts="${3:-}"
  if [ "$prompt" != "Condition mode" ]; then
    echo "[Error] unexpected prompt: $prompt" >&2
    return 1
  fi
  if [ "$opts" != "and" ]; then
    echo "[Error] expected reordered options to remain a single default entry, got: '$opts'" >&2
    return 1
  fi
  printf -v "$__var" '%s' "and"
  return 0
}

out_mode=""
if ! _sr_prompt_mode out_mode "and"; then
  echo "[Error] _sr_prompt_mode should succeed when only default mode is available." >&2
  exit 1
fi

if [ "$out_mode" != "and" ]; then
  echo "[Error] _sr_prompt_mode selected unexpected value: '$out_mode'" >&2
  exit 1
fi

echo "security rule prompt mode single-default guard passed."
