#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/security_rule_update_interactive.sh
source "$ROOT_DIR/lib/cli/security_rule_update_interactive.sh"

INTERACTIVE=true
SECURITY_RULE_STATUS=403
STATE_SECURITY_RULES_COLS=45
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""

TEST_CASE="ok"

function get_arg_choices() {
  local cmd="${1:-}" arg="${2:-}"
  if [ "$cmd" = "update-security-rule" ] && [ "$arg" = "id" ]; then
    echo "1,Rule 1"
  fi
}

function _sr_prompt_choice() {
  local __var="${1:-}" prompt="${2:-}"
  case "$prompt" in
  "Select security rule")
    printf -v "$__var" '%s' "1"
    ;;
  "Replace conditions?")
    printf -v "$__var" '%s' "replace"
    ;;
  *)
    printf -v "$__var" '%s' ""
    ;;
  esac
}

function _sr_load_line() {
  echo "dummy"
}

function csv_parse_line() {
  CSV_FIELDS=()
  local i
  for ((i = 0; i < STATE_SECURITY_RULES_COLS; i++)); do
    CSV_FIELDS+=("-")
  done
  CSV_FIELDS[0]="1"
  CSV_FIELDS[1]="e2e-http.example.com"
  CSV_FIELDS[2]="single"
  CSV_FIELDS[3]="-"
  CSV_FIELDS[4]="1"
  CSV_FIELDS[5]="header"
  CSV_FIELDS[6]="User-Agent"
  CSV_FIELDS[7]="contains"
  CSV_FIELDS[8]="BadBot"
  CSV_FIELD_COUNT="$STATE_SECURITY_RULES_COLS"
  return 0
}

function summarize_cond() {
  local src="${1:-}" name="${2:-}" cond="${3:-}" val="${4:-}"
  echo "${src}:${name} ${cond} ${val}"
}

function read_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}"
  if [[ "$_prompt" == Status\ code\ override* ]]; then
    printf -v "$__var" '%s' ""
  else
    printf -v "$__var" '%s' "$default"
  fi
}

function is_back_input() { return 1; }
function is_valid_domain() { return 0; }
function backend_exists() { return 0; }

function _sr_prompt_count() {
  local __var="${1:-}"
  printf -v "$__var" '%s' "2"
}

function _sr_prompt_mode() {
  local __var="${1:-}"
  printf -v "$__var" '%s' "and"
}

function _sr_collect_condition_quads() {
  if [ "$TEST_CASE" = "ok" ]; then
    SR_COLLECTED_CONDS=(
      "header" "User-Agent" "contains" "BadBot"
      "method" "-" "equals" "GET"
    )
    SR_COLLECTED_SUMMARIES=(
      "header:User-Agent contains BadBot"
      "method equals GET"
    )
  else
    SR_COLLECTED_CONDS=("header" "User-Agent" "contains" "BadBot")
    SR_COLLECTED_SUMMARIES=("header:User-Agent contains BadBot")
  fi
}

function run_success_case() {
  TEST_CASE="ok"
  PROMPT_ARGS_COLLECTED=()
  if ! prompt_args_handle_update_security_rule_interactive update-security-rule; then
    echo "[Error] update-security-rule interactive replace flow should succeed with valid collected payload." >&2
    return 1
  fi
  local expected=(
    "1"
    "--count" "2"
    "header" "User-Agent" "contains" "BadBot"
    "method" "-" "equals" "GET"
    "--mode" "and"
  )
  if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne "${#expected[@]}" ]; then
    echo "[Error] update-security-rule collected arg count mismatch." >&2
    return 1
  fi
  local i
  for i in "${!expected[@]}"; do
    if [ "${PROMPT_ARGS_COLLECTED[$i]}" != "${expected[$i]}" ]; then
      echo "[Error] update-security-rule arg mismatch at index $i." >&2
      return 1
    fi
  done
}

function run_mismatch_case() {
  TEST_CASE="bad_len"
  PROMPT_ARGS_COLLECTED=()
  if prompt_args_handle_update_security_rule_interactive update-security-rule; then
    echo "[Error] update-security-rule interactive replace flow should fail on condition count/length mismatch." >&2
    return 1
  fi
}

run_success_case
run_mismatch_case

echo "update-security-rule interactive replace collection guard checks passed."
