# shellcheck shell=bash

function _prompt_args_review_or_return() {
  local cmd="${1:-}"
  shift || true
  if [ "$INTERACTIVE" != true ] || ! declare -F review_command_before_run >/dev/null 2>&1; then
    return 0
  fi
  case "$cmd" in
  add-security-rule)
    return 0
    ;;
  esac
  review_command_before_run "$cmd" "$@"
}

function _prompt_args_clear_selection() {
  PROMPT_ARGS_COLLECTED=()
  SELECTED_ARGS=()
  SELECTED_CMD=""
}

function _prompt_args_review_selected_or_return() {
  if [ ${#SELECTED_ARGS[@]} -gt 0 ]; then
    _prompt_args_review_or_return "${SELECTED_CMD:-}" "${SELECTED_ARGS[@]}"
  else
    _prompt_args_review_or_return "${SELECTED_CMD:-}"
  fi
}

# Prompt for the arguments of the provided command using the same logic as the main picker
function prompt_args_for_command() {
  local CMD="$1"
  CURRENT_CMD="$CMD"
  CURRENT_ARGS=()
  PROMPT_ARGS_CONTEXT=()
  SELECTED_CMD=""
  SELECTED_ARGS=()
  PROMPT_ARGS_COLLECTED=()
  local args=()
  local handler_status=0

  if declare -F cli_prompt_cache_reset >/dev/null 2>&1; then
    cli_prompt_cache_reset
  fi

  if [ "$INTERACTIVE" = true ] && [ "$CMD" = "add-backend" ]; then
    collect_add_backend_interactive
    handler_status=$?
    if [ "$handler_status" -ne 0 ]; then
      _prompt_args_clear_selection
      return "$handler_status"
    fi
    _prompt_args_review_selected_or_return
    handler_status=$?
    if [ "$handler_status" -ne 0 ]; then
      _prompt_args_clear_selection
      return "$handler_status"
    fi
    return 0
  fi
  if [ "$INTERACTIVE" = true ] && [ "$CMD" = "add-host-alias" ]; then
    collect_add_host_alias_interactive
    handler_status=$?
    if [ "$handler_status" -ne 0 ]; then
      _prompt_args_clear_selection
      return "$handler_status"
    fi
    _prompt_args_review_selected_or_return
    handler_status=$?
    if [ "$handler_status" -ne 0 ]; then
      _prompt_args_clear_selection
      return "$handler_status"
    fi
    return 0
  fi

  if [ "$INTERACTIVE" = true ]; then
    prompt_args_handle_headers "$CMD"
    handler_status=$?
    case "$handler_status" in
    0)
      _prompt_args_review_selected_or_return
      handler_status=$?
      if [ "$handler_status" -ne 0 ]; then
        _prompt_args_clear_selection
        return "$handler_status"
      fi
      return 0
      ;;
    1)
      _prompt_args_clear_selection
      return 1
      ;;
    esac
  fi

  if [ "$INTERACTIVE" = true ] && cmd_requires_existing_backend "$CMD" && ! has_backends; then
    echo "[Info] No backends configured." >&2
    read -rp "Press Enter to continue..." _
    _prompt_args_clear_selection
    return 1
  fi

  if [ "$INTERACTIVE" = true ] && declare -F prompt_args_handle_nginx_directives >/dev/null 2>&1; then
    prompt_args_handle_nginx_directives "$CMD"
    case $? in
    0)
      SELECTED_CMD="$CMD"
      if [ ${#PROMPT_ARGS_COLLECTED[@]} -gt 0 ]; then
        SELECTED_ARGS=("${PROMPT_ARGS_COLLECTED[@]}")
      else
        SELECTED_ARGS=()
      fi
      _prompt_args_review_selected_or_return
      handler_status=$?
      if [ "$handler_status" -ne 0 ]; then
        _prompt_args_clear_selection
        return "$handler_status"
      fi
      return 0
      ;;
    1)
      _prompt_args_clear_selection
      return 1
      ;;
    esac
  fi

  prompt_args_handle_security_specials "$CMD"
  handler_status=$?
  case "$handler_status" in
  0)
    SELECTED_CMD="$CMD"
    if [ ${#PROMPT_ARGS_COLLECTED[@]} -gt 0 ]; then
      SELECTED_ARGS=("${PROMPT_ARGS_COLLECTED[@]}")
    else
      SELECTED_ARGS=()
    fi
    _prompt_args_review_selected_or_return
    handler_status=$?
    if [ "$handler_status" -ne 0 ]; then
      _prompt_args_clear_selection
      return "$handler_status"
    fi
    return 0
    ;;
  1)
    _prompt_args_clear_selection
    return 1
    ;;
  esac

  local spec=""
  if spec="$(get_arg_spec "$CMD" 2>/dev/null)"; then
    if [[ -n "$spec" ]]; then
      local spec_idx=0
      local -a arg_prompted=()
      cli_parse_arg_spec "$spec"
      while ((spec_idx < ${#CLI_SPEC_NAMES[@]})); do
        local name="${CLI_SPEC_NAMES[$spec_idx]}" default="${CLI_SPEC_DEFAULTS[$spec_idx]}" val="" prompt hint opts
        local backtrack_requested=false

        if [ ${#args[@]} -gt 0 ]; then
          PROMPT_ARGS_CONTEXT=("${args[@]}")
        else
          PROMPT_ARGS_CONTEXT=()
        fi
        default="$(prompt_args_compute_default "$CMD" "$name" "$default")"

        if [[ "$CMD" == "update-backend" && "$name" == "docker_opts" ]]; then
          local cur_opts
          cur_opts="$(get_backend_docker_opts "backend:${args[0]}")"
          [[ -n "$cur_opts" ]] && echo "Current docker options: $cur_opts"
        fi
        if [[ ("$CMD" == "start-nginx" || "$CMD" == "set-nginx-docker-opts") && "$name" == "docker_opts" ]]; then
          [[ -n "${NGINX_DOCKER_OPTS:-}" ]] && echo "Current Nginx docker options: $NGINX_DOCKER_OPTS"
        fi

        # Skip cert prompt when protocol != https for add-backend and add-port
        if [[ "$name" == "cert_path" ]]; then
          local __proto=""
          if [[ "$CMD" == "add-backend" ]]; then
            # args so far: domain, image, container_port, protocol, listen
            __proto="${args[3]:-}"
          elif [[ "$CMD" == "add-port" ]]; then
            # args so far: domain, nginx_port, container_port, protocol
            __proto="${args[3]:-}"
          fi
          if [[ -n "$__proto" && "$__proto" != "https" ]]; then
            # For add-port, store placeholder 'none' to align with spec
            if [[ "$CMD" == "add-port" ]]; then
              args+=("none")
            else
              args+=("")
            fi
            arg_prompted+=("skipped")
            spec_idx=$((spec_idx + 1))
            continue
          fi
        fi
        # legacy tcp command hints removed in unified mode
        local label help_text example_text empty_behavior_text prompt_newline
        prompt_newline=$'\n'
        label="$(arg_label "$name")"
        prompt="$label"
        hint="$(arg_option_hint "$name")"
        [[ -n "$hint" ]] && hint="${hint//$'\n'/ }" && prompt+=" ($hint)"
        help_text="$(arg_help "$CMD" "$name")"
        example_text="$(arg_example "$CMD" "$name")"
        empty_behavior_text="$(arg_empty_behavior "$CMD" "$name")"
        if [[ -n "$example_text" ]]; then
          prompt+="${prompt_newline}Example: ${example_text}"
        fi
        if [[ -n "$empty_behavior_text" ]]; then
          prompt+="${prompt_newline}Blank: ${empty_behavior_text}"
        fi
        if [[ -n "$help_text" ]]; then
          prompt="${help_text}${prompt_newline}${prompt}"
        fi
        if [[ "$CMD" == "add-port" && "$name" == "cert_path" ]]; then
          local __ctx_domain="${args[0]:-}"
          local __ctx_nginx_port="${args[1]:-}"
          local __ctx_container_port="${args[2]:-}"
          local __ctx_protocol="${args[3]:-}"
          prompt="$(arg_review_label domain): ${__ctx_domain}${prompt_newline}$(arg_review_label nginx_port): ${__ctx_nginx_port}${prompt_newline}$(arg_review_label container_port): ${__ctx_container_port}${prompt_newline}$(arg_review_label protocol): ${__ctx_protocol}${prompt_newline}${prompt}"
        fi
        if [[ "$name" == "ws" ]]; then
          local __proto_ws=""
          if [[ "$CMD" == "add-backend" ]]; then
            __proto_ws="${args[3]:-}"
          elif [[ "$CMD" == "add-port" ]]; then
            __proto_ws="${args[3]:-}"
          fi
          if [[ "$__proto_ws" == "tcp" || "$__proto_ws" == "udp" ]]; then
            args+=("no")
            arg_prompted+=("skipped")
            spec_idx=$((spec_idx + 1))
            continue
          fi
        fi
        if [[ "$CMD" == "add-port" && ( "$name" == "http3" || "$name" == "alt_svc" ) ]]; then
          local __proto_http3="${args[3]:-}"
          if [[ -n "$__proto_http3" && "$__proto_http3" != "https" ]]; then
            args+=("$default")
            arg_prompted+=("skipped")
            spec_idx=$((spec_idx + 1))
            continue
          fi
        fi
        if [ "${#args[@]}" -gt 0 ]; then
          CURRENT_ARGS=("${args[@]}")
        else
          CURRENT_ARGS=()
        fi
        opts="$(get_arg_choices "$CMD" "$name")"
        if [[ -z "$opts" && "$name" == "domain" ]]; then
          if no_domain_overrides_message "$CMD"; then
            return 1
          fi
        fi
        if [[ -z "$opts" && "$name" == "header" ]]; then
          if no_header_overrides_message "$CMD"; then
            return 1
          fi
        fi
        if [[ -z "$opts" && "$name" == "port" ]]; then
          if no_port_tls_overrides_message "$CMD"; then
            return 1
          fi
        fi
        if [[ -n "$opts" ]]; then
          local _vals=() _disp=() line choice_value choice_label idx
          while IFS= read -r line; do
            choice_value=""
            choice_label=""
            cli_choice_line_to_value_label "$line" choice_value choice_label
            _vals+=("$choice_value")
            _disp+=("$choice_label")
          done <<<"$opts"
          if [ "$INTERACTIVE" = true ] && [ -n "$default" ]; then
            mark_current_option "$default"
          fi

          if [ "$INTERACTIVE" = true ]; then
            _vals+=("__BACK__")
            _disp+=("Back")
            if ! choose_option idx "$prompt:" "${_disp[@]}"; then
              backtrack_requested=true
            elif [ -z "${idx-}" ] || ! [ "$idx" -ge 0 ] 2>/dev/null || [ "$idx" -ge ${#_vals[@]} ] 2>/dev/null; then
              backtrack_requested=true
            else
              val="${_vals[$idx]}"
              if [ "$val" = "__BACK__" ]; then
                backtrack_requested=true
              fi
              if [[ "$name" == "docker_opts" && "$val" == "__DEFAULT__" ]]; then
                val="$default"
              elif [[ "$name" == "docker_opts" && "$val" == "__CLEAR__" ]]; then
                if [[ "$CMD" == "update-backend" ]]; then
                  val="__DOCKER_OPTS_CLEAR__"
                else
                  val="__NGINX_DOCKER_OPTS_CLEAR__"
                fi
              elif [[ "$name" == "docker_opts" && "$val" == "__MANUAL__" ]]; then
                read_multiline_with_editing "${prompt} (finish with empty line): " val
                if [ "$INTERACTIVE" = true ] && is_back_input "$val"; then
                  backtrack_requested=true
                fi
              elif [[ "$val" == "__MANUAL__" ]]; then
                read_with_editing "${prompt}: " val
                if [ "$INTERACTIVE" = true ] && is_back_input "$val"; then
                  backtrack_requested=true
                fi
              fi
            fi
          else
            if [[ "$name" == "docker_opts" ]]; then
              if [[ -n "$default" ]]; then
                read_multiline_with_editing "${prompt} (finish with empty line; blank keeps current): " val "$default"
              else
                read_multiline_with_editing "${prompt} (finish with empty line): " val
              fi
            else
              if [[ -n "$default" ]]; then
                read_with_editing "$prompt [$default]: " val "$default"
              else
                read_with_editing "$prompt: " val
              fi
            fi
            [[ -z "$val" ]] && val="$default"
          fi
        else
          if [[ "$name" == "docker_opts" ]]; then
            if [[ -n "$default" ]]; then
              read_multiline_with_editing "${prompt} (finish with empty line; blank keeps current): " val "$default"
            else
              read_multiline_with_editing "${prompt} (finish with empty line): " val
            fi
          else
            if [[ -n "$default" ]]; then
              read_with_editing "$prompt [$default]: " val "$default"
            else
              read_with_editing "$prompt: " val
            fi
          fi
          [[ -z "$val" ]] && val="$default"
          if [ "$INTERACTIVE" = true ] && is_back_input "$val"; then
            backtrack_requested=true
          fi
        fi
        if [ "$backtrack_requested" = true ]; then
          if [ ${#args[@]} -eq 0 ]; then
            _prompt_args_clear_selection
            return 1
          fi
          local previous_idx=-1
          while [ ${#args[@]} -gt 0 ]; do
            local last_idx=$(( ${#args[@]} - 1 ))
            local was_prompted="${arg_prompted[$last_idx]:-prompted}"
            args=("${args[@]:0:$last_idx}")
            arg_prompted=("${arg_prompted[@]:0:$last_idx}")
            if [ "$was_prompted" = "prompted" ]; then
              previous_idx="$last_idx"
              break
            fi
          done
          if [ "$previous_idx" -lt 0 ]; then
            _prompt_args_clear_selection
            return 1
          fi
          spec_idx="$previous_idx"
          continue
        fi
        args+=("$val")
        arg_prompted+=("prompted")
        spec_idx=$((spec_idx + 1))
      done
    else
      args=()
    fi
  else
    local i=1 arg
    while true; do
      read_with_editing "Argument $i for $CMD (leave empty to finish): " arg
      if is_back_input "$arg"; then
        _prompt_args_clear_selection
        return 1
      fi
      [[ -z $arg ]] && break
      args+=("$arg")
      ((i++))
    done
  fi

  if [ ${#args[@]} -gt 0 ]; then
    PROMPT_ARGS_COLLECTED=("${args[@]}")
  else
    PROMPT_ARGS_COLLECTED=()
  fi
  if ! prompt_args_postprocess "$CMD"; then
    _prompt_args_clear_selection
    return 1
  fi
  if [ ${#PROMPT_ARGS_COLLECTED[@]} -gt 0 ]; then
    args=("${PROMPT_ARGS_COLLECTED[@]}")
  else
    args=()
  fi

  local review_status=0
  if [ ${#args[@]} -gt 0 ]; then
    _prompt_args_review_or_return "$CMD" "${args[@]}"
  else
    _prompt_args_review_or_return "$CMD"
  fi
  review_status=$?
  if [ "$review_status" -ne 0 ]; then
    _prompt_args_clear_selection
    return "$review_status"
  fi

  SELECTED_CMD="$CMD"
  if [ ${#args[@]} -gt 0 ]; then
    SELECTED_ARGS=("${args[@]}")
  else
    SELECTED_ARGS=()
  fi
}
