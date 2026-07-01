# shellcheck shell=bash

function _prompt_args_headers_operator_value_for_display() {
  local kind="${1:-}" value="${2:-}"
  if declare -F operator_value_for_display >/dev/null 2>&1; then
    operator_value_for_display "$kind" "$value"
  else
    printf '%s' "$value"
  fi
}

# Return codes: 0 handled, 1 back/abort, 2 not handled
function prompt_args_handle_headers() {
  local CMD="$1"
  case "$CMD" in
  set-hsts)
    local cur_hsts
    cur_hsts="$(get_global_header_value "Strict-Transport-Security")"
    read_with_editing "HSTS value (Off to remove)${cur_hsts:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur_hsts")]}: " cur_hsts "$cur_hsts"
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
    cur_csp="$(get_global_header_value "Content-Security-Policy")"
    if [ -n "$cur_csp" ]; then
      echo "[Info] Current global CSP: $(_prompt_args_headers_operator_value_for_display header_value "$cur_csp")"
    else
      echo "[Info] Current global CSP: <none>"
    fi
    if [ -f "$BACKEND_HEADERS_FILE" ]; then
      local b_csp
      local line="" line_no=0
      b_csp=""
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        csv_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || continue
        if [ "${CSV_FIELDS[1]}" = "response" ] && [ "${CSV_FIELDS[2]}" = "Content-Security-Policy" ]; then
          b_csp="${b_csp} ${CSV_FIELDS[0]}=$(_prompt_args_headers_operator_value_for_display header_value "${CSV_FIELDS[3]}")"
        fi
      done <"$BACKEND_HEADERS_FILE"
      b_csp="$(printf '%s' "$b_csp" | xargs)"
      [ -n "$b_csp" ] && echo "[Info] Backend CSP overrides: ${b_csp}"
    fi
    read_with_editing "CSP value (Off to remove)${cur_csp:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur_csp")]}: " cur_csp "$cur_csp"
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
    cur="$(get_backend_header_value "$domain" "Strict-Transport-Security")"
    [ -n "$cur" ] || cur="$(get_global_header_value "Strict-Transport-Security")"
    read_with_editing "HSTS for ${domain} (Off to remove)${cur:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur")]}: " val "$cur"
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
    cur="$(get_backend_header_value "$domain" "Content-Security-Policy")"
    [ -n "$cur" ] || cur="$(get_global_header_value "Content-Security-Policy")"
    if [ -n "$cur" ]; then
      echo "[Info] Current CSP for ${domain}: $(_prompt_args_headers_operator_value_for_display header_value "$cur")"
    else
      echo "[Info] Current CSP for ${domain}: <none>"
    fi
    read_with_editing "CSP for ${domain} (Off to remove)${cur:+ [$(_prompt_args_headers_operator_value_for_display header_value "$cur")]}: " val "$cur"
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
