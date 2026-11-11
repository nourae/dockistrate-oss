# shellcheck shell=bash

function prompt_args_handle_add_security_rule_interactive() {
  local CMD="$1"
  if [ "$INTERACTIVE" != true ]; then
    return 2
  fi
  local domain="" action="" count="" mode="" code="" confirm_choice=""
  if ! _sr_prompt_domain domain "$CMD"; then
    return 1
  fi
  if ! _sr_prompt_action action; then return 1; fi
  if ! _sr_prompt_count count "1"; then
    return 1
  fi
  if ((count > 1)); then
    if ! _sr_prompt_mode mode "and"; then
      return 1
    fi
  fi
  if [ "$action" != allow ] && ! _sr_prompt_code_optional code "false"; then
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
  local summary="Security rule summary"
  summary+=$'\n'"  Domain: $domain"
  summary+=$'\n'"  Action: $action"
  summary+=$'\n'"  Conditions: $count"
  if ((count > 1)); then
    summary+=$'\n'"  Mode: $mode"
  fi
  if [ "$action" = allow ]; then
    summary+=$'\n''  Rejection: none; later Block/Allow decisions are skipped when conditions match'
  elif [ -n "$code" ]; then
    summary+=$'\n'"  Code: $code"
  else
    summary+=$'\n'"  Code: default (${SECURITY_RULE_STATUS:-})"
  fi
  local idx
  for idx in "${!SR_COLLECTED_SUMMARIES[@]}"; do
    summary+=$'\n'"  - ${SR_COLLECTED_SUMMARIES[$idx]}"
  done
  summary+=$'\n\n''Create security rule?'
  local CLI_PROMPT_LITERAL=true
  if ! _sr_prompt_choice confirm_choice "$summary" $'confirm|Confirm\nback|Back' "false"; then
    return 1
  fi
  if [ "$confirm_choice" != "confirm" ]; then
    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 1
  fi
  local args=("$domain" "$count" "${SR_COLLECTED_CONDS[@]}")
  args+=(--action "$action")
  if ((count > 1)); then
    args+=(--mode "$mode")
  fi
  if [ -n "$code" ]; then
    args+=(--code "$code")
  fi
  PROMPT_ARGS_COLLECTED=("${args[@]}")
  return 0
}
