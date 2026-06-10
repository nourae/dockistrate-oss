#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/security_acl_interactive.sh
source "$ROOT_DIR/lib/cli/security_acl_interactive.sh"

INTERACTIVE=true
CURRENT_ARGS=()
SELECTED_CMD=""
SELECTED_ARGS=()
PROMPT_ARGS_COLLECTED=()

CHOICE_CURSOR=0
CHOICE_QUEUE=(0 0 0)

function get_arg_spec() {
  local cmd="${1:-}"
  if [ "$cmd" != "add-acl" ]; then
    return 1
  fi
  printf '%s' 'domain,;scope,l7;allow_or_deny,allow;ip_list,;status_code,403'
}

function get_arg_choices() {
  local cmd="${1:-}" arg="${2:-}"
  [ "$cmd" = "add-acl" ] || return 0
  case "$arg" in
  domain)
    printf '%s\n' "$(csv_join_row "e2e-http.example.com" "e2e-http.example.com")"
    ;;
  scope | allow_or_deny)
    # Intentionally empty to force fallback branch coverage.
    ;;
  esac
}

function arg_option_hint() {
  local name="${1:-}"
  case "$name" in
  scope)
    echo "l7|Layer 7 (\$remote_addr, also used for TCP streams)"
    echo "l3|Layer 3 (\$realip_remote_addr)"
    echo "both|Apply to L7 and L3 (TCP uses client IP)"
    ;;
  allow_or_deny)
    echo "allow|Allow"
    echo "deny|Deny"
    ;;
  ip_list)
    echo "ip or cidr..."
    ;;
  *)
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
  local _prompt="${1:-}" __var="${2:-}" _default="${3:-}"
  printf -v "$__var" '%s' "172.19.0.1"
}

function is_back_input() { return 1; }
function mark_current_option() { :; }
function _validator_for() { :; }
function ensure_valid_or_prompt() { :; }

if ! prompt_args_handle_add_acl_interactive add-acl; then
  echo "[Error] interactive add-acl handler failed unexpectedly while using fallback choices." >&2
  exit 1
fi

expected=("e2e-http.example.com" "l7" "allow" "172.19.0.1")
if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne "${#expected[@]}" ]; then
  echo "[Error] Expected ${#expected[@]} collected ACL args, got ${#PROMPT_ARGS_COLLECTED[@]}." >&2
  exit 1
fi

idx=0
for idx in "${!expected[@]}"; do
  if [ "${PROMPT_ARGS_COLLECTED[$idx]}" != "${expected[$idx]}" ]; then
    echo "[Error] ACL collected arg ${idx} mismatch: expected '${expected[$idx]}', got '${PROMPT_ARGS_COLLECTED[$idx]}'." >&2
    exit 1
  fi
done

echo "interactive ACL scope/action fallback CSV-safety guard passed."
