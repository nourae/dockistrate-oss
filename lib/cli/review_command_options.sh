# shellcheck shell=bash

# These collectors produce execution flags, rather than the positional prompt
# spec. Read the display-safe argv without modifying the execution arguments.
function _review_command_option_label() {
  case "${1:-}:${2:-}" in
  update-path-option:--new-path) printf '%s' 'New path prefix' ;;
  update-path-option:--nginx-port) printf '%s' 'New listen port' ;;
  uninstall-all:--scope) arg_review_label uninstall_scope ;;
  start-nginx:--nginx-image) arg_review_label nginx_image ;;
  start-nginx:--docker-opts) arg_review_label docker_opts ;;
  update-security-rule:--action) printf '%s' 'Action' ;;
  update-security-rule:--mode) printf '%s' 'Condition combination' ;;
  update-security-rule:--domain) arg_review_label domain ;;
  update-security-rule:--code) arg_review_label code ;;
  add-path-option:--ws | update-path-option:--ws) arg_review_label ws ;;
  add-path-option:--redirect | update-path-option:--redirect) arg_review_label redirect ;;
  add-path-option:--headers | update-path-option:--headers) arg_review_label headers ;;
  add-path-option:--match | update-path-option:--match) arg_review_label match ;;
  add-path-option:--priority | update-path-option:--priority) arg_review_label priority ;;
  add-path-option:--target | update-path-option:--target) arg_review_label target ;;
  add-path-option:--rewrite | update-path-option:--rewrite) arg_review_label rewrite ;;
  add-path-option:--reason | update-path-option:--reason | update-security-rule:--reason) arg_review_label reason ;;
  add-path-option:--loc | update-path-option:--loc | update-security-rule:--loc) arg_review_label loc ;;
  *) return 1 ;;
  esac
}

function _review_command_summary_row() {
  printf '  %s: %s\n' "$(_review_command_display_value "${1:-}")" "$(_review_command_display_value "${2:-}")"
}

function _review_command_format_option_summary() {
  local cmd="${1:-}" idx=0 prefix=0 name="" label="" value="" option=""
  local count=0 condition=0 field=""
  local args=() names=()
  shift || true
  _review_display_args_for_command "$cmd" "$@"
  if [ "${#REVIEW_DISPLAY_ARGS[@]}" -gt 0 ]; then
    args=("${REVIEW_DISPLAY_ARGS[@]}")
  else
    printf '  (none)\n'
    return 0
  fi
  case "$cmd" in
  add-path-option | update-path-option) names=(domain nginx_port path_prefix); prefix=3 ;;
  update-security-rule) names=(id); prefix=1 ;;
  esac
  while [ "$idx" -lt "$prefix" ] && [ "$idx" -lt "${#args[@]}" ]; do
    name="${names[$idx]}"
    label="$(arg_review_label "$name")"
    if [ "$cmd" = update-path-option ]; then
      case "$name" in
      nginx_port) label='Current listen port' ;;
      path_prefix) label='Current path prefix' ;;
      esac
    fi
    _review_command_summary_row "$label" "${args[$idx]}"
    idx=$((idx + 1))
  done
  while [ "$idx" -lt "${#args[@]}" ]; do
    option="${args[$idx]}"
    idx=$((idx + 1))
    if [ "$cmd:$option" = update-security-rule:--count ]; then
      count="${args[$idx]:-}"
      idx=$((idx + 1))
      # Keep malformed operands visible without arithmetic evaluation of input.
      case "$count" in
      [1-9] | 10) ;;
      *) _review_command_summary_row 'Invalid condition count' "$count"; continue ;;
      esac
      _review_command_summary_row 'Condition count' "$count"
      condition=1
      while [ "$condition" -le "$count" ]; do
        for field in Source Name Test Value; do
          if [ "$idx" -lt "${#args[@]}" ]; then
            value="${args[$idx]}"
            idx=$((idx + 1))
          else
            value='(missing)'
          fi
          _review_command_summary_row "Condition $condition — $field" "$value"
        done
        condition=$((condition + 1))
      done
    elif label="$(_review_command_option_label "$cmd" "$option")"; then
      if [ "$idx" -lt "${#args[@]}" ]; then
        value="${args[$idx]}"
        idx=$((idx + 1))
        if [ "$cmd:$option" = start-nginx:--docker-opts ] && [ -z "$value" ]; then
          value='(clear)'
        elif [ "$cmd:$option" = update-security-rule:--code ] && { [ -z "$value" ] || [ "$value" = - ]; }; then
          value='Inherited default'
        fi
      else
        value='(missing)'
      fi
      _review_command_summary_row "$label" "$value"
    else
      _review_command_summary_row 'Unrecognized argument' "$option"
    fi
  done
}
