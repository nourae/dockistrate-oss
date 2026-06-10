#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/prompts.sh
source "$ROOT_DIR/lib/utils/prompts.sh"

function assert_normalizes_to() {
  local raw="$1" default_answer="$2" expected="$3" actual=""
  if ! actual="$(normalize_yes_no_answer "$raw" "$default_answer")"; then
    echo "[Error] Expected '$raw' with default '$default_answer' to normalize to '$expected'." >&2
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "[Error] Expected '$raw' with default '$default_answer' to normalize to '$expected', got '$actual'." >&2
    exit 1
  fi
}

function assert_invalid_answer() {
  local raw="$1" default_answer="${2:-}"
  if normalize_yes_no_answer "$raw" "$default_answer" >/dev/null 2>&1; then
    echo "[Error] Expected '$raw' with default '$default_answer' to be rejected." >&2
    exit 1
  fi
}

assert_normalizes_to "yes" "" "yes"
assert_normalizes_to "Y" "" "yes"
assert_normalizes_to "on" "" "yes"
assert_normalizes_to "no" "" "no"
assert_normalizes_to "N" "" "no"
assert_normalizes_to "off" "" "no"
assert_normalizes_to "" "yes" "yes"
assert_normalizes_to "" "no" "no"
assert_invalid_answer "maybe" ""
assert_invalid_answer "xno" ""

READ_QUEUE=()
function read_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" _default="${3:-}" value=""
  [ -n "$__var" ] || return 1
  if [ "${#READ_QUEUE[@]}" -gt 0 ]; then
    value="${READ_QUEUE[0]}"
    READ_QUEUE=("${READ_QUEUE[@]:1}")
  fi
  printf -v "$__var" '%s' "$value"
}

READ_QUEUE=("")
read_yes_no_with_default result "Question [Y/n]: " "yes"
if [ "$result" != "yes" ]; then
  echo "[Error] Blank answer with default yes should resolve to yes." >&2
  exit 1
fi

READ_QUEUE=("maybe" "N")
read_yes_no_with_default result "Question [Y/n]: " "yes"
if [ "$result" != "no" ]; then
  echo "[Error] Invalid answer should re-prompt until a normalized no is provided." >&2
  exit 1
fi
if [ "${#READ_QUEUE[@]}" -ne 0 ]; then
  echo "[Error] Expected read_yes_no_with_default to consume both queued answers." >&2
  exit 1
fi

echo "[tests] yes_no_prompt_normalization.sh: PASS"
