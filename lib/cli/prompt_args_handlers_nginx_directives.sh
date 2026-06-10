# shellcheck shell=bash

function _prompt_nginx_directive_pick_value() {
  local __out_var="${1:-}" prompt="${2:-}" options_text="${3:-}" allow_manual="${4:-false}"
  local values=()
  local labels=()
  local line="" parsed_value="" parsed_label="" idx=0 selected=""

  require_valid_var_name "$__out_var" || return 1

  if [ -n "$options_text" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cli_choice_line_to_value_label "$line" parsed_value parsed_label
      values+=("$parsed_value")
      labels+=("$parsed_label")
    done <<<"$options_text"
  fi

  if [ "$allow_manual" = "true" ]; then
    values+=("__MANUAL__")
    labels+=("Enter manually...")
  fi
  values+=("__BACK__")
  labels+=("Back")

  if ! choose_option idx "${prompt}:" "${labels[@]}"; then
    return 1
  fi
  selected="${values[$idx]}"

  case "$selected" in
  __BACK__)
    return 1
    ;;
  __MANUAL__)
    read_with_editing "${prompt}: " selected
    if [ "$INTERACTIVE" = true ] && is_back_input "$selected"; then
      return 1
    fi
    ;;
  esac

  printf -v "$__out_var" '%s' "$selected"
  return 0
}

function prompt_args_handle_nginx_directives() {
  local CMD="$1"
  local scope="" domain="" port="" path_prefix="" directive="" value=""
  local scope_choices="" directive_choices="" domain_choices="" port_choices="" path_choices=""

  case "$CMD" in
  set-nginx-directive | set-nginx-directive-raw | remove-nginx-directive | remove-all-nginx-directives | list-nginx-directives)
    ;;
  *)
    return 2
    ;;
  esac

  scope_choices="$(get_arg_choices "$CMD" "directive_scope")"
  if [ -z "$scope_choices" ]; then
    if [ "$CMD" = "remove-all-nginx-directives" ] || [ "$CMD" = "list-nginx-directives" ]; then
      scope_choices=$'all\nglobal\nbackend\nport\npath\nstream-global\nstream-backend\nstream-port'
    else
      scope_choices=$'global\nbackend\nport\npath\nstream-global\nstream-backend\nstream-port'
    fi
  fi

  if ! _prompt_nginx_directive_pick_value scope "directive_scope" "$scope_choices" "false"; then
    return 1
  fi

  if [ "$scope" = "backend" ] || [ "$scope" = "port" ] || [ "$scope" = "path" ] || [ "$scope" = "stream-backend" ] || [ "$scope" = "stream-port" ]; then
    CURRENT_ARGS=("$scope")
    domain_choices="$(get_arg_choices "$CMD" "domain")"
    if ! _prompt_nginx_directive_pick_value domain "domain" "$domain_choices" "true"; then
      return 1
    fi
  fi

  if [ "$scope" = "port" ] || [ "$scope" = "path" ] || [ "$scope" = "stream-port" ]; then
    CURRENT_ARGS=("$scope" "$domain")
    port_choices="$(get_arg_choices "$CMD" "port")"
    if ! _prompt_nginx_directive_pick_value port "port" "$port_choices" "true"; then
      return 1
    fi
  fi

  if [ "$scope" = "path" ]; then
    CURRENT_ARGS=("$scope" "$domain" "$port")
    path_choices="$(get_arg_choices "$CMD" "path_prefix")"
    if ! _prompt_nginx_directive_pick_value path_prefix "path_prefix" "$path_choices" "true"; then
      return 1
    fi
  fi

  case "$CMD" in
  set-nginx-directive | set-nginx-directive-raw | remove-nginx-directive)
    case "$scope" in
    global | stream-global)
      CURRENT_ARGS=("$scope")
      ;;
    backend | stream-backend)
      CURRENT_ARGS=("$scope" "$domain")
      ;;
    port | stream-port)
      CURRENT_ARGS=("$scope" "$domain" "$port")
      ;;
    path)
      CURRENT_ARGS=("$scope" "$domain" "$port" "$path_prefix")
      ;;
    esac
    directive_choices="$(get_arg_choices "$CMD" "directive_name")"
    if ! _prompt_nginx_directive_pick_value directive "directive_name" "$directive_choices" "true"; then
      return 1
    fi
    ;;
  esac

  case "$CMD" in
  set-nginx-directive | set-nginx-directive-raw)
    read_with_editing "directive_value: " value
    if [ "$INTERACTIVE" = true ] && is_back_input "$value"; then
      return 1
    fi
    ;;
  esac

  case "$CMD" in
  set-nginx-directive | set-nginx-directive-raw)
    case "$scope" in
    global) PROMPT_ARGS_COLLECTED=("$scope" "$directive" "$value") ;;
    backend) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$directive" "$value") ;;
    port) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port" "$directive" "$value") ;;
    path) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port" "$path_prefix" "$directive" "$value") ;;
    stream-global) PROMPT_ARGS_COLLECTED=("$scope" "$directive" "$value") ;;
    stream-backend) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$directive" "$value") ;;
    stream-port) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port" "$directive" "$value") ;;
    esac
    ;;
  remove-nginx-directive)
    case "$scope" in
    global) PROMPT_ARGS_COLLECTED=("$scope" "$directive") ;;
    backend) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$directive") ;;
    port) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port" "$directive") ;;
    path) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port" "$path_prefix" "$directive") ;;
    stream-global) PROMPT_ARGS_COLLECTED=("$scope" "$directive") ;;
    stream-backend) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$directive") ;;
    stream-port) PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port" "$directive") ;;
    esac
    ;;
  remove-all-nginx-directives | list-nginx-directives)
    case "$scope" in
    all)
      PROMPT_ARGS_COLLECTED=()
      ;;
    global)
      PROMPT_ARGS_COLLECTED=("$scope")
      ;;
    backend)
      PROMPT_ARGS_COLLECTED=("$scope" "$domain")
      ;;
    port)
      PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port")
      ;;
    path)
      PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port" "$path_prefix")
      ;;
    stream-global)
      PROMPT_ARGS_COLLECTED=("$scope")
      ;;
    stream-backend)
      PROMPT_ARGS_COLLECTED=("$scope" "$domain")
      ;;
    stream-port)
      PROMPT_ARGS_COLLECTED=("$scope" "$domain" "$port")
      ;;
    esac
    ;;
  esac

  return 0
}
