# shellcheck shell=bash

function prompt_args_handle_add_acl_interactive() {
  local CMD="$1" spec="${2:-}"
  if [ -z "$spec" ]; then
    spec="$(get_arg_spec "$CMD" 2>/dev/null || true)"
  fi
  if [ -z "$spec" ]; then
    return 2
  fi
  cli_parse_arg_spec "$spec"
  if [ "${#CLI_SPEC_NAMES[@]}" -lt 4 ]; then
    return 2
  fi
  local args=()
  local name default val prompt hint opts

  # domain
  name="${CLI_SPEC_NAMES[0]}"
  default="${CLI_SPEC_DEFAULTS[0]}"
  prompt="$name"
  hint="$(arg_option_hint "$name")"
  [[ -n "$hint" ]] && hint="${hint//$'\n'/ }" && prompt+=" ($hint)"
  if [ "${#args[@]}" -gt 0 ]; then CURRENT_ARGS=("${args[@]}"); else CURRENT_ARGS=(); fi
  opts="$(get_arg_choices "$CMD" "$name")"
  if [[ -n "$opts" ]]; then
    local _vals=() _disp=() line choice_val choice_label
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cli_choice_line_to_value_label "$line" choice_val choice_label
      _vals+=("$choice_val")
      _disp+=("$choice_label")
    done <<<"$opts"
    if [ "$INTERACTIVE" = true ] && [ -n "$default" ]; then
      local __has_default=false __item
      for __item in "${_vals[@]}"; do
        if [ "$__item" = "__DEFAULT__" ]; then
          __has_default=true
          break
        fi
      done
      if ! $__has_default; then
        _vals+=("__DEFAULT__")
        _disp+=("Keep current: $default")
      fi
    fi
    if [ "$INTERACTIVE" = true ]; then
      _vals+=("__BACK__")
      _disp+=("Back")
    fi
    if ! choose_option idx "$prompt:" "${_disp[@]}"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    val="${_vals[$idx]}"
    # If user chooses sentinel options, handle accordingly
    if [ "$val" = "__DEFAULT__" ]; then
      # Fill with computed default to keep current value explicitly
      val="$default"
    elif [ "$val" = "__BACK__" ]; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    elif [ "$val" = "__MANUAL__" ]; then
      local __validator
      __validator="$(_validator_for "$CMD" "$name")"
      if [ -n "$__validator" ]; then
        ensure_valid_or_prompt val "" "$name" "$default" "$__validator"
      else
        if [[ -n "$default" ]]; then
          read_with_editing "$prompt [$default]: " val "$default"
        else
          read_with_editing "$prompt: " val
        fi
        [[ -z "$val" ]] && val="$default"
      fi
    fi
  else
    if [[ -n "$default" ]]; then
      read_with_editing "$prompt [$default]: " val "$default"
    else
      read_with_editing "$prompt: " val
    fi
    [[ -z "$val" ]] && val="$default"
    if [ "$INTERACTIVE" = true ] && is_back_input "$val"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
  fi
  args+=("$val")

  # scope (l7|l3|both)
  name="${CLI_SPEC_NAMES[1]}"
  default="${CLI_SPEC_DEFAULTS[1]}"
  prompt="$name"
  hint="$(arg_option_hint "$name")"
  [[ -n "$hint" ]] && hint="${hint//$'\n'/ }" && prompt+=" ($hint)"
  if [ "${#args[@]}" -gt 0 ]; then CURRENT_ARGS=("${args[@]}"); else CURRENT_ARGS=(); fi
  opts="$(get_arg_choices "$CMD" "$name")"
  if [[ -z "$opts" ]]; then
    opts="$(csv_join_row "l7" "Layer 7 (\$remote_addr, also used for TCP streams)")"$'\n'
    opts+="$(csv_join_row "l3" "Layer 3 (\$realip_remote_addr)")"$'\n'
    opts+="$(csv_join_row "both" "Apply to L7 and L3 (TCP uses client IP)")"
  fi
  if [[ -n "$opts" ]]; then
    local _vals=() _disp=() line choice_val choice_label
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cli_choice_line_to_value_label "$line" choice_val choice_label
      _vals+=("$choice_val")
      _disp+=("$choice_label")
    done <<<"$opts"
    _vals+=("__BACK__")
    _disp+=("Back")
    if ! choose_option idx "$prompt:" "${_disp[@]}"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    val="${_vals[$idx]}"
    if [ "$val" = "__BACK__" ]; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
  else
    while true; do
      if [[ -n "$default" ]]; then
        read_with_editing "$prompt [$default]: " val "$default"
      else
        read_with_editing "$prompt: " val
      fi
      [[ -z "$val" ]] && val="$default"
      if is_back_input "$val"; then
        SELECTED_CMD=""
        SELECTED_ARGS=()
        return 1
      fi
      break
    done
  fi
  args+=("$val")

  # action allow|deny (menu with Back)
  name="${CLI_SPEC_NAMES[2]}"
  default="${CLI_SPEC_DEFAULTS[2]}"
  prompt="$name"
  hint="$(arg_option_hint "$name")"
  [[ -n "$hint" ]] && hint="${hint//$'\n'/ }" && prompt+=" ($hint)"
  if [ "${#args[@]}" -gt 0 ]; then CURRENT_ARGS=("${args[@]}"); else CURRENT_ARGS=(); fi
  opts="$(get_arg_choices "$CMD" "$name")"
  if [[ -z "$opts" ]]; then
    opts="$(csv_join_row "allow" "Allow")"$'\n'
    opts+="$(csv_join_row "deny" "Deny")"
  fi
  if [[ -n "$opts" ]]; then
    local _vals=() _disp=() line choice_val choice_label
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cli_choice_line_to_value_label "$line" choice_val choice_label
      _vals+=("$choice_val")
      _disp+=("$choice_label")
    done <<<"$opts"
    if [ "$INTERACTIVE" = true ] && [ -n "$default" ]; then
      mark_current_option "$default"
    fi
    if [ "$INTERACTIVE" = true ]; then
      _vals+=("__BACK__")
      _disp+=("Back")
    fi
    if ! choose_option idx "$prompt:" "${_disp[@]}"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    val="${_vals[$idx]}"
    if [ "$val" = "__BACK__" ]; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
  else
    read_with_editing "$prompt [${default:-allow}]: " val "${default:-allow}"
    [[ -z "$val" ]] && val="$default"
    if is_back_input "$val"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
  fi
  args+=("$val")
  local acl_action="$val"

  # IP list (required)
  name="${CLI_SPEC_NAMES[3]}"
  default="${CLI_SPEC_DEFAULTS[3]}"
  prompt="$name"
  hint="$(arg_option_hint "$name")"
  [[ -n "$hint" ]] && hint="${hint//$'\n'/ }" && prompt+=" ($hint)"
  while true; do
    local ip_input=""
    if [[ -n "$default" ]]; then
      read_with_editing "$prompt [$default]: " ip_input "$default"
    else
      read_with_editing "$prompt: " ip_input
    fi
    [[ -z "$ip_input" ]] && ip_input="$default"
    if is_back_input "$ip_input"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    local -a ip_vals=()
    read -r -a ip_vals <<<"$ip_input"
    if ((${#ip_vals[@]} == 0)) || [[ -z "${ip_vals[0]}" ]]; then
      echo "[Error] Please provide at least one IP or CIDR." >&2
      continue
    fi
    local ip
    for ip in "${ip_vals[@]}"; do
      args+=("$ip")
    done
    break
  done

  # status_code only for deny
  if [[ "$acl_action" == "deny" ]]; then
    name="${CLI_SPEC_NAMES[4]}"
    default="${CLI_SPEC_DEFAULTS[4]}"
    prompt="$name"
    hint="$(arg_option_hint "$name")"
    [[ -n "$hint" ]] && hint="${hint//$'\n'/ }" && prompt+=" ($hint)"
    if [[ -n "$default" ]]; then
      read_with_editing "$prompt [$default]: " val "$default"
    else
      read_with_editing "$prompt: " val
    fi
    [[ -z "$val" ]] && val="$default"
    if is_back_input "$val"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    args+=("$val")
  fi

  PROMPT_ARGS_COLLECTED=("${args[@]}")
  return 0
}
