# shellcheck shell=bash

# shellcheck source=review_command_options.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_command_options.sh"

function command_is_mutating() {
  local cmd="${1:-}"
  case "$cmd" in
  "" | help | help-update | upgrade-preflight | validate-domain-config | status | status-all | check-config | tail-proxy-logs | list-* | show-*)
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

function _review_display_args_for_command() {
  cli_classify_visibility_args "$@"
  REVIEW_DISPLAY_ARGS=()
  if [ "${#CLI_VISIBILITY_DISPLAY_ARGS[@]}" -gt 0 ]; then
    REVIEW_DISPLAY_ARGS=("${CLI_VISIBILITY_DISPLAY_ARGS[@]}")
  fi
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
  update-backend)
    _review_format_update_backend_cli_equivalent "$@"
    ;;
  *)
    format_cli_equivalent "$@"
    ;;
  esac
}

function _review_format_update_backend_cli_equivalent() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  if { [ "${#args[@]}" -ne 5 ] && [ "${#args[@]}" -ne 6 ]; } || [[ "${args[1]:-}" == --* ]]; then
    format_cli_equivalent "$cmd" "$@"
    return 0
  fi

  local cli_args=("${args[0]}")
  if [ -n "${args[1]:-}" ] && [ "${args[1]}" != __DEFAULT__ ]; then
    cli_args+=(--image "${args[1]}")
  fi
  if [ -n "${args[2]:-}" ] && [ "${args[2]}" != __DEFAULT__ ]; then
    cli_args+=(--container-port "${args[2]}")
  fi
  if [ "${args[3]:-}" = __DOCKER_OPTS_CLEAR__ ]; then
    cli_args+=(--docker-opts "")
  elif [ -n "${args[3]:-}" ] && [ "${args[3]}" != __DEFAULT__ ]; then
    cli_args+=(--docker-opts "${args[3]}")
  fi
  if [ -n "${args[4]:-}" ] && [ "${args[4]}" != __DEFAULT__ ]; then
    cli_args+=(--network "${args[4]}")
  fi
  [ -z "${args[5]:-}" ] || cli_args+=(--replace-unmanaged-container "${args[5]}")
  # Classify this display-only command as CLI flags, rather than applying the
  # interactive positional Docker-options index to its rendered arguments.
  local INTERACTIVE=false
  format_cli_equivalent "$cmd" "${cli_args[@]}"
}

function _review_command_arg_names() {
  local cmd="${1:-}" spec="" scope=""
  case "$cmd" in
  add-backend)
    printf '%s\n' domain image container_port protocol listen cert_path ws docker_opts network expose redirect_pref redirect_target
    return 0
    ;;
  set-nginx-directive | set-nginx-directive-raw | remove-nginx-directive)
    scope="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' directive_scope
    case "$scope" in
    backend | stream-backend) printf '%s\n' domain ;;
    port | stream-port) printf '%s\n' domain port ;;
    path) printf '%s\n' domain port path_prefix ;;
    esac
    printf '%s\n' directive_name
    if [ "$cmd" != remove-nginx-directive ]; then
      printf '%s\n' directive_value
    fi
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
  case "$cmd" in
  add-path-option | update-path-option | update-security-rule | start-nginx | uninstall-all)
    _review_command_format_option_summary "$cmd" "$@"
    return 0
    ;;
  update-acl)
    printf '  ID: %s\n' "$(_review_command_display_value "${1:-}")"
    shift || true
    local acl_label="" acl_value=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
      --domain) acl_label=Domain ;;
      --scope) acl_label=Scope ;;
      --action) acl_label=Action ;;
      --ip) acl_label='IP or CIDR' ;;
      --code) acl_label='Status override' ;;
      *) acl_label="$1" ;;
      esac
      acl_value="${2:-}"
      if [ "$1" = --code ] && [ -z "$acl_value" ]; then acl_value='Inherited default'; fi
      printf '  %s: %s\n' "$(_review_command_display_value "$acl_label")" "$(_review_command_display_value "$acl_value")"
      shift
      [ "$#" -eq 0 ] || shift
    done
    return 0
    ;;
  init-domain-config | validate-domain-config | apply-domain-config | migrate-state | restore-backup)
    local config_target="" config_kind="backend" details_file="" config_action="Apply" option=""
    while [ "$#" -gt 0 ]; do
      option="$1"
      shift
      case "$option" in
      --kind) config_kind="${1:-}"; shift || true ;;
      --backend-details) details_file="${1:-}"; shift || true ;;
      --dry-run) config_action="Review only" ;;
      --all) config_target="All domains" ;;
      *) config_target="$option" ;;
      esac
    done
    if [ "$cmd" = restore-backup ]; then
      printf '  Backup: %s\n' "$(_review_command_display_value "$config_target")"
      if [ -n "$details_file" ]; then
        printf '  Backend details CSV: %s\n' "$(_review_command_display_value "$details_file")"
      fi
    elif [ "$cmd" = migrate-state ]; then
      printf '  Action: %s\n' "$config_action"
      printf '  Backend details CSV: %s\n' "$(_review_command_display_value "${details_file:-Use existing state and containers}")"
    else
      printf '  Domain: %s\n' "$(_review_command_display_value "$config_target")"
      if [ "$cmd" = init-domain-config ]; then
        printf '  Domain kind: %s\n' "$(_review_command_display_value "$config_kind")"
      elif [ "$cmd" = apply-domain-config ]; then
        printf '  Action: %s\n' "$config_action"
      fi
    fi
    return 0
    ;;
  esac
  if [ "$cmd" = "add-port" ]; then
    _review_command_format_add_port_arg_summary "$cmd" "$@"
    return 0
  fi
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
  done < <(_review_command_arg_names "$cmd" "$@")

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

function _review_command_format_add_port_arg_summary() {
  local cmd="${1:-}"
  shift || true
  local args=() names=(domain nginx_port container_port protocol cert_path ws)
  _review_display_args_for_command "$cmd" "$@"
  if [ "${#REVIEW_DISPLAY_ARGS[@]}" -gt 0 ]; then
    args=("${REVIEW_DISPLAY_ARGS[@]}")
  fi
  local idx=0 http3=off alt_svc=auto option=""
  while [ "$idx" -lt 6 ] && [ "$idx" -lt "${#args[@]}" ]; do
    printf '  %s: %s\n' "$(arg_review_label "${names[$idx]}")" "$(_review_command_display_value "${args[$idx]}")"
    idx=$((idx + 1))
  done
  while [ "$idx" -lt "${#args[@]}" ]; do
    option="${args[$idx]}"
    case "$option" in
    --http3)
      idx=$((idx + 1))
      http3="${args[$idx]:-}"
      ;;
    --alt-svc)
      idx=$((idx + 1))
      alt_svc="${args[$idx]:-}"
      ;;
    *) printf '  Argument %s: %s\n' "$((idx + 1))" "$(_review_command_display_value "$option")" ;;
    esac
    idx=$((idx + 1))
  done
  if [ "${args[3]:-}" = https ]; then
    printf '  %s: %s\n' "$(arg_review_label http3)" "$(_review_command_display_value "$http3")"
    printf '  %s: %s\n' "$(arg_review_label alt_svc)" "$(_review_command_display_value "$alt_svc")"
  fi
  [ "${#args[@]}" -gt 0 ] || printf '  (none)\n'
  return 0
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

  case "$cmd" in
  apply-domain-config | migrate-state)
    local preview_arg=""
    for preview_arg in "$@"; do
      [ "$preview_arg" != --dry-run ] || return 0
    done
    ;;
  esac

  if ! command_is_mutating "$cmd"; then
    return 0
  fi

  local domain_review_status=0
  if declare -F _review_domain_config_pending >/dev/null 2>&1; then
    _review_domain_config_pending "$cmd" "$@" || domain_review_status=$?
    if [ "$domain_review_status" -ne 0 ]; then
      SELECTED_CMD=""
      SELECTED_ARGS=()
      return "$domain_review_status"
    fi
  fi
  if declare -F _review_domain_config_candidate >/dev/null 2>&1 &&
    ! _review_domain_config_candidate "$cmd" "$@"; then
    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 1
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
