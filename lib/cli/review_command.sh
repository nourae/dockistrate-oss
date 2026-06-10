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

function format_cli_equivalent() {
  local cmd="${1:-}"
  shift || true
  local out="./dockistrate.sh"
  out+=" $(_review_shell_quote "$cmd")"
  local arg
  for arg in "$@"; do
    out+=" $(_review_shell_quote "$arg")"
  done
  printf '%s\n' "$out"
}

function _review_format_add_backend_cli_equivalent() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  if [ "${#args[@]}" -lt 4 ]; then
    format_cli_equivalent "$cmd" "${args[@]}"
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
  [ -n "$docker_opts" ] && cli+=" --docker-opts $(_review_shell_quote "$docker_opts")"
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
  local value="${1:-}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

function _review_command_format_arg_summary() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
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
