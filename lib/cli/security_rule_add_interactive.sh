# shellcheck shell=bash

function prompt_args_handle_add_security_rule_interactive() {
  local CMD="$1"
  if [ "$INTERACTIVE" != true ]; then
    return 2
  fi
  local domain="" count="" mode="" code="" confirm_choice=""
  if ! _sr_prompt_domain domain "$CMD"; then
    return 1
  fi
  if ! _sr_prompt_count count "1"; then
    return 1
  fi
  if ((count > 1)); then
    if ! _sr_prompt_mode mode "and"; then
      return 1
    fi
  fi
  if ! _sr_prompt_code_optional code "false"; then
    return 1
  fi
  if ! _sr_collect_condition_quads "$CMD" "$count"; then
    return 1
  fi
  if [ -z "$domain" ]; then
    echo "[Error] Internal interactive collection failure: missing domain for security rule." >&2
    return 1
  fi
  if ! [[ "$count" =~ ^(10|[1-9])$ ]]; then
    echo "[Error] Internal interactive collection failure: invalid condition count '${count:-}'." >&2
    return 1
  fi
  local expected_condition_fields=$((count * 4))
  local actual_condition_fields=${#SR_COLLECTED_CONDS[@]}
  if [ "$actual_condition_fields" -ne "$expected_condition_fields" ]; then
    echo "[Error] Internal interactive collection failure: expected ${expected_condition_fields} condition fields, got ${actual_condition_fields}." >&2
    return 1
  fi
  echo "[Info] Security rule summary"
  echo "  Domain: $domain"
  echo "  Conditions: $count"
  if ((count > 1)); then
    echo "  Mode: $mode"
  fi
  if [ -n "$code" ]; then
    echo "  Code: $code"
  else
    echo "  Code: default (${SECURITY_RULE_STATUS:-})"
  fi
  local idx
  for idx in "${!SR_COLLECTED_SUMMARIES[@]}"; do
    echo "  - ${SR_COLLECTED_SUMMARIES[$idx]}"
  done
  if ! _sr_prompt_choice confirm_choice "Create security rule?" $'confirm|Confirm\nback|Back' "false"; then
    return 1
  fi
  if [ "$confirm_choice" != "confirm" ]; then
    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 1
  fi
  local args=("$domain" "$count" "${SR_COLLECTED_CONDS[@]}")
  if ((count > 1)); then
    args+=(--mode "$mode")
  fi
  if [ -n "$code" ]; then
    args+=(--code "$code")
  fi
  PROMPT_ARGS_COLLECTED=("${args[@]}")
  return 0
}
