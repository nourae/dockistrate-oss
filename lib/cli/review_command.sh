# shellcheck shell=bash

function command_is_mutating() {
  local cmd="${1:-}"
  case "$cmd" in
  "" | help | help-update | upgrade-preflight | status | status-all | check-config | tail-proxy-logs | list-* | show-*)
    return 1
    ;;
  esac
  return 0
}

function command_is_destructive() {
  local cmd="${1:-}"
  case "$cmd" in
  remove-* | clean-all | uninstall-all | revoke-*)
    return 0
    ;;
  esac
  return 1
}

function _review_shell_quote() {
  local value="${1:-}"
  if [[ "$value" =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]; then
    local escaped="" rest="$value" char
    while [ -n "$rest" ]; do
      char="${rest:0:1}"
      rest="${rest:1}"
      case "$char" in
      $'\n')
        escaped+="\\n"
        ;;
      $'\r')
        escaped+="\\r"
        ;;
      $'\t')
        escaped+="\\t"
        ;;
      "\\")
        escaped+="\\\\"
        ;;
      "'")
        escaped+="\\'"
        ;;
      *)
        escaped+="$char"
        ;;
      esac
    done
    printf "\$'%s'" "$escaped"
    return 0
  fi

  local quoted="'" rest="$value" sq="'"
  while [[ "$rest" == *"$sq"* ]]; do
    quoted+="${rest%%"$sq"*}'\\''"
    rest="${rest#*"$sq"}"
  done
  quoted+="$rest'"
  printf '%s' "$quoted"
}

function _review_operator_arg_value_for_display() {
  local cmd="${1:-}" arg_name="${2:-}" value="${3:-}"
  if declare -F operator_arg_value_for_display >/dev/null 2>&1; then
    operator_arg_value_for_display "$cmd" "$arg_name" "$value"
  else
    printf '%s' "$value"
  fi
}

REVIEW_DISPLAY_ARGS=()

function _review_sensitive_arg_consumes_remainder() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  set-nginx-docker-opts:docker_opts)
    return 0
    ;;
  esac
  return 1
}

function _review_sensitive_arg_redacts_trailing_words() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  add-header:value | update-header:value \
  | add-backend-header:value | update-backend-header:value \
  | set-hsts:hsts_value | set-backend-hsts:backend_hsts_value \
  | set-csp:csp_value | set-backend-csp:backend_csp_value)
    return 0
    ;;
  esac
  return 1
}

function _review_should_redact_sensitive_remainder() {
  local cmd="${1:-}" arg_name="${2:-}" idx="${3:-0}" arg_count="${4:-0}"
  [ -n "$arg_name" ] || return 1
  _review_arg_is_sensitive "$cmd" "$arg_name" || return 1
  _review_sensitive_arg_consumes_remainder "$cmd" "$arg_name" || return 1
  [ "$idx" -lt "$((arg_count - 1))" ] 2>/dev/null
}

function _review_is_redaction_boundary_option() {
  local cmd="${1:-}" option="${2:-}"
  case "${cmd}:${option}" in
  add-backend:--no-expose)
    return 0
    ;;
  esac
  return 1
}

function _review_next_arg_is_cli_option() {
  local cmd="${1:-}" next_arg="${2:-}" option=""
  [ -n "$next_arg" ] || return 1
  option="$next_arg"
  if [[ "$next_arg" == --*=* ]]; then
    option="${next_arg%%=*}"
  fi
  _review_is_redaction_boundary_option "$cmd" "$option" && return 0
  [ -n "$(_review_arg_name_for_option "$option" || true)" ]
}

function _review_should_redact_sensitive_trailing_words() {
  local cmd="${1:-}" arg_name="${2:-}" next_arg="${3:-}"
  [ -n "$arg_name" ] || return 1
  [ -n "$next_arg" ] || return 1
  _review_arg_is_sensitive "$cmd" "$arg_name" || return 1
  if _review_sensitive_arg_redacts_trailing_words "$cmd" "$arg_name" ||
    [ "$arg_name" = "docker_opts" ]; then
    ! _review_next_arg_is_cli_option "$cmd" "$next_arg"
    return
  fi
  return 1
}

function _review_should_stop_after_redacted_value() {
  local cmd="${1:-}" arg_name="${2:-}" value="${3:-}" next_arg="${4:-}"
  _review_sensitive_arg_consumes_remainder "$cmd" "$arg_name" && return 0
  _review_sensitive_arg_redacts_trailing_words "$cmd" "$arg_name" && return 0
  if [ "$arg_name" = "docker_opts" ] && [[ "$value" == --* ]] &&
    [ -n "$next_arg" ] && ! _review_next_arg_is_cli_option "$cmd" "$next_arg"; then
    return 0
  fi
  return 1
}

function _review_arg_name_for_option() {
  local option="${1:-}" normalized="" spec_arg_name=""
  case "$option" in
  --*) normalized="${option#--}" ;;
  *) return 1 ;;
  esac
  normalized="${normalized//-/_}"
  [ "${#CLI_SPEC_NAMES[@]}" -gt 0 ] 2>/dev/null || return 1

  for spec_arg_name in "${CLI_SPEC_NAMES[@]}"; do
    if [ "$spec_arg_name" = "$normalized" ]; then
      printf '%s\n' "$spec_arg_name"
      return 0
    fi
  done

  return 1
}

function _review_arg_index_for_name() {
  local __arg_idx_var="${1:-}" target_name="${2:-}"
  local spec_idx=0

  require_valid_var_name "$__arg_idx_var" || return 1
  [ -n "$target_name" ] || return 1
  [ "${#CLI_SPEC_NAMES[@]}" -gt 0 ] 2>/dev/null || return 1

  for spec_idx in "${!CLI_SPEC_NAMES[@]}"; do
    if [ "${CLI_SPEC_NAMES[$spec_idx]}" = "$target_name" ]; then
      printf -v "$__arg_idx_var" '%s' "$spec_idx"
      return 0
    fi
  done

  return 1
}

function _review_arg_is_sensitive() {
  declare -F arg_is_sensitive >/dev/null 2>&1 || return 1
  arg_is_sensitive "$@"
}

function _review_display_args_for_command() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  local spec="" idx=0 arg="" arg_name="" positional_idx=0
  local consume_next_option_value=false consume_next_option_arg_name=""
  local next_arg="" sensitive_value=false option_idx=0 consume_next_option_spec_idx=0

  REVIEW_DISPLAY_ARGS=()
  if declare -F get_arg_spec >/dev/null 2>&1 &&
    declare -F cli_parse_arg_spec >/dev/null 2>&1; then
    spec="$(get_arg_spec "$cmd" 2>/dev/null || true)"
    cli_parse_arg_spec "$spec"
  else
    CLI_SPEC_NAMES=()
  fi

  if [ "${#args[@]}" -eq 0 ]; then
    return 0
  fi

  for idx in "${!args[@]}"; do
    arg="${args[$idx]}"
    if [ "$consume_next_option_value" = true ]; then
      next_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 1))" ]; then
        next_arg="${args[$((idx + 1))]}"
      fi
      sensitive_value=false
      if [ -n "$consume_next_option_arg_name" ] &&
        _review_arg_is_sensitive "$cmd" "$consume_next_option_arg_name" "$arg"; then
        sensitive_value=true
        REVIEW_DISPLAY_ARGS+=("$OPERATOR_VISIBILITY_REDACTED_VALUE")
      elif _review_should_redact_sensitive_trailing_words "$cmd" "$consume_next_option_arg_name" "$next_arg"; then
        REVIEW_DISPLAY_ARGS+=("$OPERATOR_VISIBILITY_REDACTED_VALUE")
        break
      else
        REVIEW_DISPLAY_ARGS+=("$arg")
      fi
      if [ "$sensitive_value" = true ] &&
        _review_should_stop_after_redacted_value "$cmd" "$consume_next_option_arg_name" "$arg" "$next_arg"; then
        break
      fi
      if [ "$positional_idx" -le "$consume_next_option_spec_idx" ] 2>/dev/null; then
        positional_idx=$((consume_next_option_spec_idx + 1))
      fi
      consume_next_option_value=false
      consume_next_option_arg_name=""
      consume_next_option_spec_idx=0
      continue
    fi

    if [[ "$arg" == --*=* ]] && arg_name="$(_review_arg_name_for_option "${arg%%=*}" || true)" && [ -n "$arg_name" ]; then
      next_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 1))" ]; then
        next_arg="${args[$((idx + 1))]}"
      fi
      if _review_arg_is_sensitive "$cmd" "$arg_name" "${arg#*=}"; then
        REVIEW_DISPLAY_ARGS+=("${arg%%=*}=${OPERATOR_VISIBILITY_REDACTED_VALUE}")
        if _review_should_stop_after_redacted_value "$cmd" "$arg_name" "${arg#*=}" "$next_arg"; then
          break
        fi
      elif _review_should_redact_sensitive_trailing_words "$cmd" "$arg_name" "$next_arg"; then
        REVIEW_DISPLAY_ARGS+=("${arg%%=*}=${OPERATOR_VISIBILITY_REDACTED_VALUE}")
        break
      else
        REVIEW_DISPLAY_ARGS+=("$arg")
      fi
      if _review_arg_index_for_name option_idx "$arg_name" &&
        [ "$positional_idx" -le "$option_idx" ] 2>/dev/null; then
        positional_idx=$((option_idx + 1))
      fi
      continue
    fi

    arg_name="$(_review_arg_name_for_option "$arg" || true)"
    if [ -n "$arg_name" ]; then
      REVIEW_DISPLAY_ARGS+=("$arg")
      consume_next_option_value=true
      consume_next_option_arg_name="$arg_name"
      consume_next_option_spec_idx=0
      _review_arg_index_for_name consume_next_option_spec_idx "$arg_name" || true
      continue
    fi

    arg_name=""
    if [ "$positional_idx" -lt "${#CLI_SPEC_NAMES[@]}" ] 2>/dev/null; then
      arg_name="${CLI_SPEC_NAMES[$positional_idx]}"
    fi
    if [[ "$arg" == --* ]] && [ -n "$arg_name" ] &&
      ! _review_arg_is_sensitive "$cmd" "$arg_name" "$arg"; then
      REVIEW_DISPLAY_ARGS+=("$arg")
      continue
    fi
    if [ -n "$arg_name" ]; then
      REVIEW_DISPLAY_ARGS+=("$(_review_operator_arg_value_for_display "$cmd" "$arg_name" "$arg")")
      if _review_arg_is_sensitive "$cmd" "$arg_name" "$arg" &&
        { _review_sensitive_arg_consumes_remainder "$cmd" "$arg_name" ||
          _review_sensitive_arg_redacts_trailing_words "$cmd" "$arg_name"; }; then
        break
      fi
      if _review_should_redact_sensitive_remainder "$cmd" "$arg_name" "$idx" "${#args[@]}"; then
        REVIEW_DISPLAY_ARGS[${#REVIEW_DISPLAY_ARGS[@]} - 1]="$OPERATOR_VISIBILITY_REDACTED_VALUE"
        break
      fi
    else
      REVIEW_DISPLAY_ARGS+=("$arg")
    fi
    positional_idx=$((positional_idx + 1))
  done
}

function format_cli_equivalent() {
  local cmd="${1:-}"
  shift || true
  local out="./dockistrate.sh"
  out+=" $(_review_shell_quote "$cmd")"
  local args=()
  local arg
  _review_display_args_for_command "$cmd" "$@"
  if [ "${#REVIEW_DISPLAY_ARGS[@]}" -gt 0 ] 2>/dev/null; then
    args=("${REVIEW_DISPLAY_ARGS[@]}")
  fi
  if [ "${#args[@]}" -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  for arg in "${args[@]}"; do
    out+=" $(_review_shell_quote "$arg")"
  done
  printf '%s\n' "$out"
}

function _review_format_add_backend_cli_equivalent() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  if [ "${#args[@]}" -lt 4 ]; then
    if [ "${#args[@]}" -gt 0 ]; then
      format_cli_equivalent "$cmd" "${args[@]}"
    else
      format_cli_equivalent "$cmd"
    fi
    return 0
  fi

  local domain="${args[0]:-}" image="${args[1]:-}" container_port="${args[2]:-}" protocol="${args[3]:-}"
  local listen="${args[4]:-}" cert_path="${args[5]:-}" ws="${args[6]:-}" docker_opts="${args[7]:-}"
  local network="${args[8]:-}" expose="${args[9]:-}" redirect_pref="${args[10]:-}" redirect_target="${args[11]:-}"
  local cli="./dockistrate.sh add-backend"

  cli+=" $(_review_shell_quote "$domain")"
  cli+=" $(_review_shell_quote "$image")"
  cli+=" $(_review_shell_quote "$container_port")"
  cli+=" $(_review_shell_quote "$protocol")"
  [ -n "$listen" ] && cli+=" --listen $(_review_shell_quote "$listen")"
  if [ "$protocol" = "https" ] && [ -n "$cert_path" ]; then
    cli+=" --cert $(_review_shell_quote "$cert_path")"
  fi
  if { [ "$protocol" = "http" ] || [ "$protocol" = "https" ]; } && [ -n "$ws" ]; then
    cli+=" --ws $(_review_shell_quote "$ws")"
  fi
  [ -n "$docker_opts" ] && cli+=" --docker-opts $(_review_shell_quote "$(_review_operator_arg_value_for_display "$cmd" docker_opts "$docker_opts")")"
  [ -n "$network" ] && cli+=" --network $(_review_shell_quote "$network")"
  case "$expose" in
  no) cli+=" --no-expose" ;;
  yes) cli+=" --expose yes" ;;
  "") ;;
  *) cli+=" --expose $(_review_shell_quote "$expose")" ;;
  esac

  printf '%s\n' "$cli"
  if [ "$protocol" = "https" ] && [ "${expose:-yes}" != "no" ] && [ "$redirect_pref" = "yes" ]; then
    [ -n "$redirect_target" ] || redirect_target="$listen"
    printf '%s\n' "./dockistrate.sh add-port $(_review_shell_quote "$domain") 80 $(_review_shell_quote "$container_port") http none no"
    printf '%s\n' "./dockistrate.sh set-port-redirect $(_review_shell_quote "$domain") 80 on $(_review_shell_quote "301:${redirect_target}")"
  fi
}

function _review_command_cli_equivalent() {
  local cmd="${1:-}"
  case "$cmd" in
  add-backend)
    _review_format_add_backend_cli_equivalent "$@"
    ;;
  *)
    format_cli_equivalent "$@"
    ;;
  esac
}

function _review_command_arg_names() {
  local cmd="${1:-}" spec=""
  case "$cmd" in
  add-backend)
    printf '%s\n' domain image container_port protocol listen cert_path ws docker_opts network expose redirect_pref redirect_target
    return 0
    ;;
  esac

  if spec="$(get_arg_spec "$cmd" 2>/dev/null)" && [ -n "$spec" ]; then
    cli_parse_arg_spec "$spec"
    if [ ${#CLI_SPEC_NAMES[@]} -gt 0 ]; then
      printf '%s\n' "${CLI_SPEC_NAMES[@]}"
    fi
  fi
}

function _review_command_display_value() {
  local value="${1:-}" cmd="${2:-}" arg_name="${3:-}"
  if [ -n "$cmd" ] && [ -n "$arg_name" ]; then
    value="$(_review_operator_arg_value_for_display "$cmd" "$arg_name" "$value")"
  fi
  value="${value//$'\r'/\\r}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

function _review_command_format_arg_summary() {
  local cmd="${1:-}"
  shift || true
  if [ "$cmd" = "update-port" ]; then
    _review_command_format_update_port_arg_summary "$cmd" "$@"
    return 0
  fi
  local args=()
  _review_display_args_for_command "$cmd" "$@"
  if [ "${#REVIEW_DISPLAY_ARGS[@]}" -gt 0 ] 2>/dev/null; then
    args=("${REVIEW_DISPLAY_ARGS[@]}")
  fi
  if [ "${#args[@]}" -eq 0 ]; then
    echo "  (none)"
    return 0
  fi

  local -a names=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && names+=("$name")
  done < <(_review_command_arg_names "$cmd")

  local idx=0 label=""
  for idx in "${!args[@]}"; do
    if [ "$idx" -lt "${#names[@]}" ]; then
      label="$(arg_review_label "${names[$idx]}")"
    else
      label="Argument $((idx + 1))"
    fi
    printf '  %s: %s\n' "$label" "$(_review_command_display_value "${args[$idx]}")"
  done
}

function _review_command_print_arg_summary() {
  _review_command_format_arg_summary "$@"
}

function _review_command_format_update_port_arg_summary() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  local domain="${args[0]:-}" current_port="${args[1]:-}" idx=2
  local nginx_port="" container_port="" protocol="" cert_path="" ws="" http3="" alt_svc="" arg=""

  while [ "$idx" -lt "${#args[@]}" ]; do
    arg="${args[$idx]:-}"
    case "$arg" in
    --nginx-port)
      idx=$((idx + 1))
      nginx_port="${args[$idx]:-}"
      ;;
    --container-port)
      idx=$((idx + 1))
      container_port="${args[$idx]:-}"
      ;;
    --protocol)
      idx=$((idx + 1))
      protocol="${args[$idx]:-}"
      ;;
    --cert)
      idx=$((idx + 1))
      cert_path="${args[$idx]:-}"
      ;;
    --ws)
      idx=$((idx + 1))
      ws="${args[$idx]:-}"
      ;;
    --http3)
      idx=$((idx + 1))
      http3="${args[$idx]:-}"
      ;;
    --alt-svc)
      idx=$((idx + 1))
      alt_svc="${args[$idx]:-}"
      ;;
    esac
    idx=$((idx + 1))
  done

  [ -n "$domain" ] && printf '  %s: %s\n' "$(arg_review_label domain)" "$(_review_command_display_value "$domain")"
  [ -n "$current_port" ] && printf '  Current listen port: %s\n' "$(_review_command_display_value "$current_port")"
  [ -n "$nginx_port" ] && printf '  New listen port: %s\n' "$(_review_command_display_value "$nginx_port")"
  [ -n "$container_port" ] && printf '  %s: %s\n' "$(arg_review_label container_port)" "$(_review_command_display_value "$container_port")"
  [ -n "$protocol" ] && printf '  %s: %s\n' "$(arg_review_label protocol)" "$(_review_command_display_value "$protocol")"
  [ -n "$cert_path" ] && printf '  %s: %s\n' "$(arg_review_label cert_path)" "$(_review_command_display_value "$cert_path")"
  [ -n "$ws" ] && printf '  %s: %s\n' "$(arg_review_label ws)" "$(_review_command_display_value "$ws")"
  [ -n "$http3" ] && printf '  %s: %s\n' "$(arg_review_label http3)" "$(_review_command_display_value "$http3")"
  [ -n "$alt_svc" ] && printf '  %s: %s\n' "$(arg_review_label alt_svc)" "$(_review_command_display_value "$alt_svc")"
  if [ -z "$domain" ] && [ "${#args[@]}" -eq 0 ]; then
    echo "  (none)"
  fi
  return 0
}

function _review_command_format_prompt() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  local alias desc prompt arg_summary cli_equivalent cli_equivalent_indented
  alias="$(command_alias "$cmd")"
  desc="$(command_description "$cmd")"
  if [ ${#args[@]} -gt 0 ]; then
    arg_summary="$(_review_command_format_arg_summary "$cmd" "${args[@]}")"
    cli_equivalent="$(_review_command_cli_equivalent "$cmd" "${args[@]}")"
  else
    arg_summary="$(_review_command_format_arg_summary "$cmd")"
    cli_equivalent="$(_review_command_cli_equivalent "$cmd")"
  fi
  cli_equivalent_indented="${cli_equivalent//$'\n'/$'\n  '}"

  prompt="Review command"
  if [ "$alias" = "$cmd" ]; then
    prompt+=$'\n'"  Command: $cmd"
  else
    prompt+=$'\n'"  Command: $alias ($cmd)"
  fi
  if [ -n "$desc" ]; then
    prompt+=$'\n'"  Description: $desc"
  fi
  prompt+=$'\n\n'"Arguments:"
  prompt+=$'\n'"$arg_summary"
  prompt+=$'\n\n'"CLI equivalent:"
  prompt+=$'\n'"  $cli_equivalent_indented"

  if command_is_destructive "$cmd"; then
    prompt+=$'\n\n'"[Warn] This command can remove or revoke existing state."
  fi
  printf '%s' "$prompt"
}

function review_command_before_run() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")

  if ! command_is_mutating "$cmd"; then
    return 0
  fi

  local idx review_prompt choose_status=0
  if [ ${#args[@]} -gt 0 ]; then
    review_prompt="$(_review_command_format_prompt "$cmd" "${args[@]}")"
  else
    review_prompt="$(_review_command_format_prompt "$cmd")"
  fi
  choose_option_with_context_status choose_status idx "review-before-run" "$review_prompt" "Run" "Edit previous answers" "Cancel"
  if [ "$choose_status" -ne 0 ]; then
    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 1
  fi
  case "$idx" in
  0)
    if command_is_destructive "$cmd"; then
      local confirm=""
      read_with_editing "Type YES to run this destructive command: " confirm
      if [ "$confirm" != "YES" ]; then
        SELECTED_CMD=""
        SELECTED_ARGS=()
        return 1
      fi
    fi
    return 0
    ;;
  1)
    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 2
    ;;
  *)
    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 1
    ;;
  esac
}
