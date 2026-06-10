# shellcheck shell=bash

# Security rule helpers for interactive flows.
function _sr_is_simple_name() {
  local n="${1:-}"
  if declare -F _sr_is_simple_selector_name >/dev/null 2>&1; then
    _sr_is_simple_selector_name "$n"
    return $?
  fi
  [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]]
}

function _sr_is_var_name() {
  local n="${1:-}"
  if declare -F _sr_is_nginx_variable_name >/dev/null 2>&1; then
    _sr_is_nginx_variable_name "$n"
    return $?
  fi
  n="${n#\$}"
  [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

function _sr_prompt_choice() {
  local __var="$1" prompt="$2" opts="$3" include_back="${4:-true}"
  local _vals=() _disp=() line idx choice_value choice_label
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    choice_value=""
    choice_label=""
    cli_choice_line_to_value_label "$line" choice_value choice_label
    _vals+=("$choice_value")
    _disp+=("$choice_label")
  done <<<"$opts"
  if [ ${#_vals[@]} -eq 0 ]; then
    return 2
  fi
  if [ "$include_back" = "true" ]; then
    _vals+=("__BACK__")
    _disp+=("Back")
  fi
  if ! choose_option idx "$prompt:" "${_disp[@]}"; then
    return 1
  fi
  local val="${_vals[$idx]}"
  if [ "$val" = "__BACK__" ]; then
    return 1
  fi
  printf -v "$__var" '%s' "$val"
  return 0
}

function _sr_prompt_domain() {
  local __var="$1" cmd="$2"
  local selected_domain="" opts
  opts="$(get_arg_choices "$cmd" domain)"
  if [ -n "$opts" ]; then
    if ! _sr_prompt_choice selected_domain "Select domain" "$opts"; then
      return 1
    fi
    printf -v "$__var" '%s' "$selected_domain"
    return 0
  fi
  while true; do
    read_with_editing "domain: " selected_domain
    if is_back_input "$selected_domain"; then
      return 1
    fi
    if ! is_valid_domain "$selected_domain"; then
      echo "[Error] Invalid domain. Please try again." >&2
      continue
    fi
    if ! backend_exists "$selected_domain"; then
      echo "[Error] Backend domain '$selected_domain' not found." >&2
      continue
    fi
    printf -v "$__var" '%s' "$selected_domain"
    return 0
  done
}

function _sr_prompt_count() {
  local __var="$1" default="${2:-1}" selected_count=""
  while true; do
    read_with_editing "Number of conditions (1-10) [${default}]: " selected_count "$default"
    if is_back_input "$selected_count"; then
      return 1
    fi
    if [[ "$selected_count" =~ ^(10|[1-9])$ ]]; then
      printf -v "$__var" '%s' "$selected_count"
      return 0
    fi
    echo "[Error] Count must be 1..10." >&2
  done
}

function _sr_prompt_mode() {
  local __var="$1" default="${2:-and}"
  local opts
  opts="$(get_arg_choices add-security-rule mode)"
  if [ -z "$opts" ]; then
    opts=$'and\nor'
  fi
  local selected_mode=""
  if [ -n "$default" ] && [ "$INTERACTIVE" = true ]; then
    local reordered=""
    if grep -qx "$default" <<<"$opts"; then
      local mode_opt=""
      reordered="$default"
      while IFS= read -r mode_opt; do
        [ "$mode_opt" = "$default" ] && continue
        reordered+=$'\n'"$mode_opt"
      done <<<"$opts"
      opts="$reordered"
    fi
  fi
  if ! _sr_prompt_choice selected_mode "Condition mode" "$opts"; then
    return 1
  fi
  printf -v "$__var" '%s' "$selected_mode"
  return 0
}

function _sr_prompt_code_optional() {
  local __var="$1" allow_clear="${2:-false}"
  local selected_code=""
  local hint="default ${SECURITY_RULE_STATUS:-}"
  if [ "$allow_clear" = "true" ]; then
    hint="${hint}, '-' to clear"
  fi
  while true; do
    read_with_editing "Status code override (leave empty for ${hint}): " selected_code
    if is_back_input "$selected_code"; then
      return 1
    fi
    if [ -z "$selected_code" ]; then
      printf -v "$__var" '%s' ""
      return 0
    fi
    if [ "$allow_clear" = "true" ] && [ "$selected_code" = "-" ]; then
      printf -v "$__var" '%s' "-"
      return 0
    fi
    if is_status_code "$selected_code"; then
      printf -v "$__var" '%s' "$selected_code"
      return 0
    fi
    echo "[Error] Invalid status code. Use 3-digit HTTP status (e.g., 403)." >&2
  done
}

function _sr_collect_condition_quads() {
  local cmd="$1" count="$2"
  SR_COLLECTED_CONDS=()
  SR_COLLECTED_SUMMARIES=()
  local i
  for ((i = 1; i <= count; i++)); do
    local src="" name="-" cond="" val="" opts=""
    opts="$(get_arg_choices "$cmd" source)"
    if [ -z "$opts" ]; then
      opts=$'header\ncookie\narg\nmethod\npath\nuri\nhost\nscheme\nip\ntls_sni\ntls_protocol\nvar'
    fi
    if ! _sr_prompt_choice src "Condition ${i} source" "$opts"; then
      return 1
    fi
    case "$src" in
    header)
      while true; do
        read_with_editing "Header name: " name
        if is_back_input "$name"; then
          return 1
        fi
        if is_valid_header_name "$name"; then
          break
        fi
        echo "[Error] Invalid header name. Use letters, digits, and hyphens." >&2
      done
      ;;
    cookie | arg)
      while true; do
        read_with_editing "Name for ${src}: " name
        if is_back_input "$name"; then
          return 1
        fi
        if _sr_is_simple_name "$name"; then
          break
        fi
        echo "[Error] Invalid name. Use letters, digits, underscores, or hyphens." >&2
      done
      ;;
    var)
      while true; do
        read_with_editing "Name for ${src}: " name
        if is_back_input "$name"; then
          return 1
        fi
        if _sr_is_var_name "$name"; then
          break
        fi
        echo "[Error] Invalid variable name. Use an optional leading dollar sign followed by letters, digits, or underscores; the first character must not be a digit." >&2
      done
      ;;
    ip)
      local scope_choice=""
      local scope_opts=""
      scope_opts+="$(csv_join_row "l7" "Client IP (remote_addr)")"$'\n'
      scope_opts+="$(csv_join_row "l3" "Real IP (realip_remote_addr)")"
      if ! _sr_prompt_choice scope_choice "IP match scope" "$scope_opts"; then
        return 1
      fi
      case "$scope_choice" in
      l3) name="l3" ;;
      *) name="l7" ;;
      esac
      ;;
    *)
      name="-"
      ;;
    esac

    opts="$(build_condition_choices_for_selector "$src" "$name")"
    if [ -z "$opts" ]; then
      opts="$(get_arg_choices "$cmd" condition)"
    fi
    if [ -z "$opts" ]; then
      opts=$'equals\nnot_equals\ncontains\nnot_contains\nstarts_with\nnot_starts_with\nends_with\nnot_ends_with\nmatches\nnot_matches\nin\nnot_in\ngt\nge\nlt\nle\nexists\nnot_exists'
    fi
    if ! _sr_prompt_choice cond "Condition ${i} operator" "$opts"; then
      return 1
    fi

    if [[ "$cond" == "exists" || "$cond" == "not_exists" ]]; then
      val="-"
    else
      while true; do
        read_with_editing "Value for ${src} ${cond}: " val
        if is_back_input "$val"; then
          return 1
        fi
        if [ -n "$val" ]; then
          break
        fi
        echo "[Error] Value cannot be empty for ${cond}." >&2
      done
    fi

    SR_COLLECTED_CONDS+=("$src" "$name" "$cond" "$val")
    local summary
    summary="$(summarize_cond "$src" "$name" "$cond" "$val")"
    SR_COLLECTED_SUMMARIES+=("$summary")
    echo "[Info] Condition ${i}: ${summary}"
  done
  return 0
}
