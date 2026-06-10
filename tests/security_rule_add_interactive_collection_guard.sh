#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/security_rule_add_interactive.sh
source "$ROOT_DIR/lib/cli/security_rule_add_interactive.sh"

INTERACTIVE=true
SECURITY_RULE_STATUS=403
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""

TEST_CASE="ok"
CONFIRM_CALLED=false

function _sr_prompt_domain() {
  local __var="${1:-}"
  printf -v "$__var" '%s' "e2e-http.example.com"
}

function _sr_prompt_count() {
  local __var="${1:-}"
  printf -v "$__var" '%s' "2"
}

function _sr_prompt_mode() {
  local __var="${1:-}"
  printf -v "$__var" '%s' "and"
}

function _sr_prompt_code_optional() {
  local __var="${1:-}"
  printf -v "$__var" '%s' ""
}

function _sr_collect_condition_quads() {
  if [ "$TEST_CASE" = "ok" ]; then
    SR_COLLECTED_CONDS=(
      "header" "User-Agent" "contains" "BadBot"
      "path" "-" "starts_with" "/admin"
    )
    SR_COLLECTED_SUMMARIES=(
      "header:User-Agent contains BadBot"
      "path starts_with /admin"
    )
  else
    SR_COLLECTED_CONDS=("header" "User-Agent" "contains" "BadBot")
    SR_COLLECTED_SUMMARIES=("header:User-Agent contains BadBot")
  fi
}

function _sr_prompt_choice() {
  local __var="${1:-}" prompt="${2:-}"
  if [ "$prompt" = "Create security rule?" ]; then
    CONFIRM_CALLED=true
    printf -v "$__var" '%s' "confirm"
  else
    printf -v "$__var" '%s' ""
  fi
}

function run_success_case() {
  TEST_CASE="ok"
  CONFIRM_CALLED=false
  PROMPT_ARGS_COLLECTED=()
  if ! prompt_args_handle_add_security_rule_interactive add-security-rule; then
    echo "[Error] add-security-rule interactive collector should succeed for valid collected payload." >&2
    return 1
  fi
  local expected=(
    "e2e-http.example.com" "2"
    "header" "User-Agent" "contains" "BadBot"
    "path" "-" "starts_with" "/admin"
    "--mode" "and"
  )
  if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne "${#expected[@]}" ]; then
    echo "[Error] add-security-rule collected arg count mismatch." >&2
    return 1
  fi
  local i
  for i in "${!expected[@]}"; do
    if [ "${PROMPT_ARGS_COLLECTED[$i]}" != "${expected[$i]}" ]; then
      echo "[Error] add-security-rule arg mismatch at index $i." >&2
      return 1
    fi
  done
  if [ "$CONFIRM_CALLED" != "true" ]; then
    echo "[Error] confirmation prompt should be reached for valid payload." >&2
    return 1
  fi
}

function run_mismatch_case() {
  TEST_CASE="bad_len"
  CONFIRM_CALLED=false
  PROMPT_ARGS_COLLECTED=()
  if prompt_args_handle_add_security_rule_interactive add-security-rule; then
    echo "[Error] add-security-rule interactive collector should fail on condition count/length mismatch." >&2
    return 1
  fi
  if [ "$CONFIRM_CALLED" = "true" ]; then
    echo "[Error] confirmation prompt should not be reached on invalid collected payload." >&2
    return 1
  fi
}

run_success_case
run_mismatch_case

echo "add-security-rule interactive collection guard checks passed."
