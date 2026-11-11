# shellcheck shell=bash

function _prompt_args_headers_operator_value_for_display() {
  local kind="${1:-}" value="${2:-}"
  if declare -F operator_value_for_display >/dev/null 2>&1; then
    operator_value_for_display "$kind" "$value"
  else
    printf '%s' "$value"
  fi
}

function _prompt_args_backend_csp_summary() {
  local records="" line="" index=0 match=-1 domain="" value=""
  local -a owners=() values=() conflicts=()
  records="$(__arg_choices_backend_header_records)" || return 1
  [ -n "$records" ] || return 0
  while IFS= read -r line; do
    csv_parse_line "$line" || return 1
    [ "${CSV_FIELDS[1]}" = response ] || continue
    [ "$(_header_name_identity "${CSV_FIELDS[2]}")" = content-security-policy ] || continue
    domain="${CSV_FIELDS[0]}"; value="${CSV_FIELDS[3]}"; match=-1
    for ((index = 0; index < ${#owners[@]}; index++)); do
      [ "${owners[index]}" != "$domain" ] || { match="$index"; break; }
    done
    if [ "$match" -lt 0 ]; then
      owners+=("$domain"); values+=("$value"); conflicts+=(false)
    elif [ "${values[match]}" != "$value" ]; then
      conflicts[match]=true
    fi
  done <<<"$records"
  for ((index = 0; index < ${#owners[@]}; index++)); do
    if [ "${conflicts[index]}" = true ]; then
      value='<conflicting values; set a replacement>'
    else
      value="$(_prompt_args_headers_operator_value_for_display header_value "${values[index]}")"
    fi
    printf '  %s=%s\n' "${owners[index]}" "$value"
  done
}

# Return codes: 0 handled, 1 back/abort, 2 not handled
function prompt_args_handle_headers() {
  local CMD="$1"
  case "$CMD" in
  set-hsts)
    local cur_hsts
    cur_hsts="$(_prompt_args_header_value '' response Strict-Transport-Security)" || return 1
    read_with_editing "HSTS value (Off to remove)${cur_hsts:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur_hsts")]}: " cur_hsts "$cur_hsts"
    [ "${INTERACTIVE:-false}" != true ] || [ "${READ_WITH_EDITING_CANCEL_REASON:-}" != eof ] || return 1
    if is_back_input "$cur_hsts"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    SELECTED_CMD="$CMD"
    [ -n "$cur_hsts" ] && SELECTED_ARGS=("$cur_hsts") || SELECTED_ARGS=("")
    return 0
    ;;
  set-csp)
    local cur_csp
    cur_csp="$(_prompt_args_header_value '' response Content-Security-Policy)" || return 1
    if [ -n "$cur_csp" ]; then
      echo "[Info] Current global CSP: $(_prompt_args_headers_operator_value_for_display header_value "$cur_csp")"
    else
      echo "[Info] Current global CSP: <none>"
    fi
    local b_csp=""
    b_csp="$(_prompt_args_backend_csp_summary)" || return 1
    [ -z "$b_csp" ] || printf '[Info] Backend CSP overrides:\n%s\n' "$b_csp"
    read_with_editing "CSP value (Off to remove)${cur_csp:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur_csp")]}: " cur_csp "$cur_csp"
    [ "${INTERACTIVE:-false}" != true ] || [ "${READ_WITH_EDITING_CANCEL_REASON:-}" != eof ] || return 1
    if is_back_input "$cur_csp"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    SELECTED_CMD="$CMD"
    [ -n "$cur_csp" ] && SELECTED_ARGS=("$cur_csp") || SELECTED_ARGS=("")
    return 0
    ;;
  set-backend-hsts)
    local domain cur val
    if ! choose_http_domain domain; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    cur="$(_prompt_args_header_value "$domain" response Strict-Transport-Security global)" || return 1
    read_with_editing "HSTS for ${domain} (Off to remove)${cur:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur")]}: " val "$cur"
    [ "${INTERACTIVE:-false}" != true ] || [ "${READ_WITH_EDITING_CANCEL_REASON:-}" != eof ] || return 1
    if is_back_input "$val"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    SELECTED_CMD="$CMD"
    SELECTED_ARGS=("$domain" "$val")
    return 0
    ;;
  set-backend-csp)
    local domain cur val
    if ! choose_http_domain domain; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    cur="$(_prompt_args_header_value "$domain" response Content-Security-Policy global)" || return 1
    if [ -n "$cur" ]; then
      echo "[Info] Current CSP for ${domain}: $(_prompt_args_headers_operator_value_for_display header_value "$cur")"
    else
      echo "[Info] Current CSP for ${domain}: <none>"
    fi
    read_with_editing "CSP for ${domain} (Off to remove)${cur:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur")]}: " val "$cur"
    [ "${INTERACTIVE:-false}" != true ] || [ "${READ_WITH_EDITING_CANCEL_REASON:-}" != eof ] || return 1
    if is_back_input "$val"; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return 1
    fi
    SELECTED_CMD="$CMD"
    SELECTED_ARGS=("$domain" "$val")
    return 0
    ;;
  esac
  return 2
}
