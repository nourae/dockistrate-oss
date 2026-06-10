# shellcheck shell=bash

function prompt_args_handle_update_security_rule_interactive() {
  local CMD="$1"
  if [ "$INTERACTIVE" != true ]; then
    return 2
  fi
  local opts id cur
  opts="$(get_arg_choices "$CMD" id)"
  if [ -z "$opts" ]; then
    echo "[Info] No security rules configured." >&2
    return 1
  fi
  if ! _sr_prompt_choice id "Select security rule" "$opts"; then
    return 1
  fi
  cur="$(_sr_load_line "$id")"
  if [ -z "$cur" ]; then
    echo "[Error] Security rule $id not found." >&2
    return 1
  fi
  if ! csv_parse_line "$cur" || [ "$CSV_FIELD_COUNT" -ne "$STATE_SECURITY_RULES_COLS" ]; then
    echo "[Error] Security rule $id is malformed." >&2
    return 1
  fi
  local e d m c n \
    s1 n1 c1 v1 \
    s2 n2 c2 v2 \
    s3 n3 c3 v3 \
    s4 n4 c4 v4 \
    s5 n5 c5 v5 \
    s6 n6 c6 v6 \
    s7 n7 c7 v7 \
    s8 n8 c8 v8 \
    s9 n9 c9 v9 \
    s10 n10 c10 v10
  e="${CSV_FIELDS[0]}"
  d="${CSV_FIELDS[1]}"
  m="${CSV_FIELDS[2]}"
  c="${CSV_FIELDS[3]}"
  n="${CSV_FIELDS[4]}"
  s1="${CSV_FIELDS[5]}"; n1="${CSV_FIELDS[6]}"; c1="${CSV_FIELDS[7]}"; v1="${CSV_FIELDS[8]}"
  s2="${CSV_FIELDS[9]}"; n2="${CSV_FIELDS[10]}"; c2="${CSV_FIELDS[11]}"; v2="${CSV_FIELDS[12]}"
  s3="${CSV_FIELDS[13]}"; n3="${CSV_FIELDS[14]}"; c3="${CSV_FIELDS[15]}"; v3="${CSV_FIELDS[16]}"
  s4="${CSV_FIELDS[17]}"; n4="${CSV_FIELDS[18]}"; c4="${CSV_FIELDS[19]}"; v4="${CSV_FIELDS[20]}"
  s5="${CSV_FIELDS[21]}"; n5="${CSV_FIELDS[22]}"; c5="${CSV_FIELDS[23]}"; v5="${CSV_FIELDS[24]}"
  s6="${CSV_FIELDS[25]}"; n6="${CSV_FIELDS[26]}"; c6="${CSV_FIELDS[27]}"; v6="${CSV_FIELDS[28]}"
  s7="${CSV_FIELDS[29]}"; n7="${CSV_FIELDS[30]}"; c7="${CSV_FIELDS[31]}"; v7="${CSV_FIELDS[32]}"
  s8="${CSV_FIELDS[33]}"; n8="${CSV_FIELDS[34]}"; c8="${CSV_FIELDS[35]}"; v8="${CSV_FIELDS[36]}"
  s9="${CSV_FIELDS[37]}"; n9="${CSV_FIELDS[38]}"; c9="${CSV_FIELDS[39]}"; v9="${CSV_FIELDS[40]}"
  s10="${CSV_FIELDS[41]}"; n10="${CSV_FIELDS[42]}"; c10="${CSV_FIELDS[43]}"; v10="${CSV_FIELDS[44]}"
  local -a cur_sources cur_names cur_conds cur_values
  cur_sources=("$s1" "$s2" "$s3" "$s4" "$s5" "$s6" "$s7" "$s8" "$s9" "$s10")
  cur_names=("$n1" "$n2" "$n3" "$n4" "$n5" "$n6" "$n7" "$n8" "$n9" "$n10")
  cur_conds=("$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")
  cur_values=("$v1" "$v2" "$v3" "$v4" "$v5" "$v6" "$v7" "$v8" "$v9" "$v10")
  local i
  local cur_count="${n:-1}"
  if ! [[ "$cur_count" =~ ^(10|[1-9])$ ]]; then
    cur_count=1
  fi
  echo "[Info] Current rule ${id}"
  echo "  Domain: $d"
  echo "  Conditions: $cur_count"
  if [ "$m" != "single" ] && [ -n "$m" ]; then
    echo "  Mode: $m"
  fi
  if [ -n "$c" ] && [ "$c" != "-" ]; then
    echo "  Code: $c"
  else
    echo "  Code: default (${SECURITY_RULE_STATUS:-})"
  fi
  for ((i = 0; i < cur_count; i++)); do
    echo "  - $(summarize_cond "${cur_sources[$i]}" "${cur_names[$i]}" "${cur_conds[$i]}" "${cur_values[$i]}")"
  done

  local new_domain="$d" new_code="$c" changed=false
  while true; do
    read_with_editing "Domain [${d}]: " new_domain "$d"
    if is_back_input "$new_domain"; then
      return 1
    fi
    if ! is_valid_domain "$new_domain"; then
      echo "[Error] Invalid domain. Please try again." >&2
      continue
    fi
    if ! backend_exists "$new_domain"; then
      echo "[Error] Backend domain '$new_domain' not found." >&2
      continue
    fi
    break
  done
  if [ "$new_domain" != "$d" ]; then
    changed=true
  fi

  local code_input="" code_hint=""
  if [ -n "$c" ] && [ "$c" != "-" ]; then
    code_hint="current $c"
  else
    code_hint="default ${SECURITY_RULE_STATUS:-}"
  fi
  while true; do
    read_with_editing "Status code override (leave empty to keep ${code_hint}, '-' to clear): " code_input
    if is_back_input "$code_input"; then
      return 1
    fi
    if [ -z "$code_input" ]; then
      new_code="$c"
      break
    fi
    if [ "$code_input" = "-" ]; then
      new_code="-"
      break
    fi
    if is_status_code "$code_input"; then
      new_code="$code_input"
      break
    fi
    echo "[Error] Invalid status code. Use 3-digit HTTP status (e.g., 403)." >&2
  done
  if [ "$new_code" != "$c" ]; then
    changed=true
  fi

  local replace_choice=""
  if ! _sr_prompt_choice replace_choice "Replace conditions?" $'keep|Keep current\nreplace|Replace' "false"; then
    return 1
  fi
  local -a new_conditions=()
  local new_count="$cur_count" new_mode="$m"
  if [ "$replace_choice" = "replace" ]; then
    changed=true
    if ! _sr_prompt_count new_count "$cur_count"; then
      return 1
    fi
    if ((new_count > 1)); then
      local default_mode="and"
      if [ "$m" != "single" ] && [ -n "$m" ]; then
        default_mode="$m"
      fi
      if ! _sr_prompt_mode new_mode "$default_mode"; then
        return 1
      fi
    else
      new_mode=""
    fi
    if ! _sr_collect_condition_quads "$CMD" "$new_count"; then
      return 1
    fi
    new_conditions=("${SR_COLLECTED_CONDS[@]}")
    if ! [[ "$new_count" =~ ^(10|[1-9])$ ]]; then
      echo "[Error] Internal interactive collection failure: invalid replacement condition count '${new_count:-}'." >&2
      return 1
    fi
    local expected_condition_fields=$((new_count * 4))
    local actual_condition_fields=${#new_conditions[@]}
    if [ "$actual_condition_fields" -ne "$expected_condition_fields" ]; then
      echo "[Error] Internal interactive collection failure: expected ${expected_condition_fields} replacement condition fields, got ${actual_condition_fields}." >&2
      return 1
    fi
  fi

  if [ "$changed" != true ]; then
    echo "[Info] No changes selected for rule ${id}."
    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 1
  fi

  local args=("$id")
  if [ "$new_domain" != "$d" ]; then
    args+=(--domain "$new_domain")
  fi
  if [ "$new_code" != "$c" ]; then
    args+=(--code "$new_code")
  fi
  if [ "$replace_choice" = "replace" ]; then
    args+=(--count "$new_count" "${new_conditions[@]}")
    if ((new_count > 1)); then
      args+=(--mode "$new_mode")
    fi
  fi

  PROMPT_ARGS_COLLECTED=("${args[@]}")
  return 0
}
