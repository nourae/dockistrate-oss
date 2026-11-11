# shellcheck shell=bash
function _add_backend_set_runtime_rollback_state() {
  ADD_BACKEND_RUNTIME_CNAME="${1:-}"
  ADD_BACKEND_RUNTIME_TOKEN="${2:-}"
  ADD_BACKEND_RUNTIME_DOMAIN="${3:-}"
  if [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then
    _domain_runtime_record add "$ADD_BACKEND_RUNTIME_DOMAIN" name "$ADD_BACKEND_RUNTIME_CNAME" new_token "$ADD_BACKEND_RUNTIME_TOKEN" || return 1
    return 0
  fi
  rollback_pre_hook_add "_add_backend_runtime_rollback_if_needed"
  _backend_runtime_install_signal_traps
}

function _add_backend_clear_runtime_rollback_state() {
  if declare -F _domain_runtime_finish_operation >/dev/null 2>&1; then
    _domain_runtime_finish_operation
  fi
  rollback_pre_hook_remove "_add_backend_runtime_rollback_if_needed"
  if [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then _backend_runtime_clear_signal_traps; fi
  unset ADD_BACKEND_RUNTIME_CNAME
  unset ADD_BACKEND_RUNTIME_TOKEN ADD_BACKEND_RUNTIME_DOMAIN
}

function _add_backend_runtime_rollback_if_needed() {
  _backend_runtime_quiet_signal_traps
  _backend_launch_cleanup "${ADD_BACKEND_RUNTIME_TOKEN:-}" "${ADD_BACKEND_RUNTIME_DOMAIN:-}"
}

function add_backend() {
  local domain="${1:-}"
  local image="${2:-}"
  local container_port="${3:-}"
  local protocol="${4:-}"
  shift 4 || true

  if [ -z "$domain" ] || [ -z "$image" ] || [ -z "$container_port" ] || [ -z "$protocol" ]; then
    echo "[Usage] add-backend <domain> <image> <container_port> <http|https|tcp|udp> [--listen port] [--cert selfsigned|letsencrypt|none|path] [--ws yes|no] [--docker-opts opts] [--network net] [--no-expose|--expose yes|no]"
    exit 1
  fi

  local listen_port="" cert_path="" ws="no" docker_opts="" network_name="$DEFAULT_NETWORK" expose_now="yes"

  # Interactive picker passes values positionally (no flags):
  #   listen, cert_path, ws, docker_opts, network, expose
  local redirect_pref="" redirect_target_port_ui=""
  if [ "$INTERACTIVE" = true ]; then
    listen_port="${1:-}"
    cert_path="${2:-}"
    ws="${3:-no}"
    docker_opts="${4:-}"
    network_name="${5:-$DEFAULT_NETWORK}"
    expose_now="${6:-yes}"
    redirect_pref="${7:-}"
    redirect_target_port_ui="${8:-}"
    # Consume the positional extras so the options parser below sees nothing
    if [ $# -ge 8 ]; then
      shift 8
    elif [ $# -ge 6 ]; then
      shift 6
    elif [ $# -gt 0 ]; then
      shift $#
    fi
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-expose)
      expose_now="no"
      shift 1
      ;;
    --expose)
      require_option_value "$@" || exit 1
      expose_now="$2"
      shift 2
      ;;
    --listen)
      require_option_value "$@" || exit 1
      listen_port="$2"
      shift 2
      ;;
    --cert)
      require_option_value "$@" || exit 1
      cert_path="$2"
      shift 2
      ;;
    --ws)
      require_option_value "$@" || exit 1
      ws="$2"
      shift 2
      ;;
    --docker-opts)
      require_option_value "$@" || exit 1
      docker_opts="$2"
      shift 2
      ;;
    --network)
      require_option_value "$@" || exit 1
      network_name="$2"
      shift 2
      ;;
    *)
      echo "[Error] Unknown option: $(operator_value_for_display docker_opts "$1")" >&2
      exit 1
      ;;
    esac
  done

  # Validate primary fields; re-prompt in interactive mode when invalid
  ensure_valid_or_prompt domain "$domain" "domain" "" is_valid_domain
  domain="$(normalize_domain "$domain")"
  if alias_exists "$domain"; then
    echo "[Error] Hostname '$domain' is already registered as an alias. Remove it before creating a backend." >&2
    exit 1
  fi
  ensure_valid_or_prompt image "$image" "image" "" is_valid_image_ref
  ensure_valid_or_prompt container_port "$container_port" "container_port" "" is_valid_port
  ensure_valid_or_prompt protocol "$protocol" "protocol" "" is_valid_protocol

  if domain_exists "$domain"; then
    echo "[Error] Backend domain '$domain' already exists. Use 'remove-backend $domain' before adding it again." >&2
    exit 1
  fi

  case "$protocol" in
  http) [ -n "$listen_port" ] || listen_port=80 ;;
  https) [ -n "$listen_port" ] || listen_port=443 ;;
  tcp | udp) [ -n "$listen_port" ] || listen_port="$container_port" ;;
  *)
    echo "[Error] Protocol must be one of http|https|tcp|udp" >&2
    exit 1
    ;;
  esac

  # Validate listen port explicitly to avoid eval-related edge cases and -e quirks
  if is_valid_port "$listen_port"; then
    listen_port="$(normalize_port "$listen_port")" || return 1
  else
    echo "[Error] Invalid listen_port: $listen_port" >&2
    exit 1
  fi
  if ! validate_http_port_combination "$protocol" "$listen_port"; then
    exit 1
  fi
  [ -n "$ws" ] || ws="no"
  ensure_valid_or_prompt ws "$ws" "ws" "no" is_yes_no
  [ -n "$network_name" ] || network_name="$DEFAULT_NETWORK"
  ensure_valid_or_prompt network_name "$network_name" "network" "$DEFAULT_NETWORK" is_valid_network_name
  ensure_valid_or_prompt expose_now "$expose_now" "expose" "$expose_now" is_yes_no

  if [ "$expose_now" = "yes" ]; then
    local host_transport="tcp"
    [ "$protocol" = "udp" ] && host_transport="udp"
    if ! assert_host_port_available_or_fail "$listen_port" "$host_transport"; then
      exit 1
    fi
  fi

  # Validate options before certificate work or any persistent/runtime mutation.
  if [ -n "$docker_opts" ]; then
    if ! docker_opts="$(normalize_docker_opts_for_storage "$docker_opts" "docker options for backend '$domain'" "backend")"; then
      return 1
    fi
  fi

  if ! begin_transaction "add_backend_${domain}" "$CONFIG_DIR" "$CERTS_DIR"; then
    exit 1
  fi

  if [ "$protocol" = "https" ]; then
    if [ -z "$cert_path" ] || [ "$cert_path" = "none" ] || [ "$cert_path" = "selfsigned" ]; then
      # Create a self-signed cert automatically for convenience
      if declare -F add_cert >/dev/null 2>&1; then
        local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
        push_skip_update_nginx_config prev_skip_update
        CERT_AUTOCONFIG_DISABLED=1 add_cert "$domain" "$listen_port" selfsigned
        pop_skip_update_nginx_config "$prev_skip_update"
        cert_path="selfsigned/live/${domain}_${listen_port}"
      else
        echo "[Error] HTTPS selected but no cert provided and cert helper unavailable." >&2
        exit 1
      fi
    elif [ "$cert_path" = "letsencrypt" ]; then
      if declare -F add_cert >/dev/null 2>&1; then
        local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
        push_skip_update_nginx_config prev_skip_update
        CERT_AUTOCONFIG_DISABLED=1 add_cert "$domain" "$listen_port" letsencrypt
        pop_skip_update_nginx_config "$prev_skip_update"
        cert_path="letsencrypt/live/${domain}_${listen_port}"
      else
        echo "[Error] HTTPS selected with Let's Encrypt but cert helper unavailable." >&2
        exit 1
      fi
    fi
    # If a cert_path is provided ensure it exists
    if [ -n "$cert_path" ] && [ "$cert_path" != "none" ]; then
      local abs_cert_dir
      if ! normalize_cert_dir abs_cert_dir "$cert_path"; then
        exit 1
      fi
      if [ ! -d "$abs_cert_dir" ]; then
        if [ "$INTERACTIVE" = true ]; then
          while true; do
            read_with_editing "Cert path under certs/ or absolute (or 'selfsigned'/'letsencrypt'): " cert_path
            if [ -z "$cert_path" ] || [ "$cert_path" = "selfsigned" ]; then
              if declare -F add_cert >/dev/null 2>&1; then
                local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
                push_skip_update_nginx_config prev_skip_update
                CERT_AUTOCONFIG_DISABLED=1 add_cert "$domain" "$listen_port" selfsigned
                pop_skip_update_nginx_config "$prev_skip_update"
                cert_path="selfsigned/live/${domain}_${listen_port}"
                break
              else
                echo "[Error] HTTPS selected with self-signed generation but cert helper unavailable." >&2
                exit 1
              fi
            fi
            if [ "$cert_path" = "letsencrypt" ]; then
              if declare -F add_cert >/dev/null 2>&1; then
                local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
                push_skip_update_nginx_config prev_skip_update
                CERT_AUTOCONFIG_DISABLED=1 add_cert "$domain" "$listen_port" letsencrypt
                pop_skip_update_nginx_config "$prev_skip_update"
                cert_path="letsencrypt/live/${domain}_${listen_port}"
                break
              else
                echo "[Error] HTTPS selected with Let's Encrypt but cert helper unavailable." >&2
                exit 1
              fi
            fi
            if ! normalize_cert_dir abs_cert_dir "$cert_path"; then
              continue
            fi
            if [ -d "$abs_cert_dir" ]; then break; fi
            echo "[Error] Directory not found: $cert_path" >&2
          done
        else
          echo "[Error] Cert directory '$cert_path' not found under '$CERTS_DIR'." >&2
          exit 1
        fi
      fi
      local stored_cert_dir
      relativize_cert_dir stored_cert_dir "$abs_cert_dir"
      cert_path="$stored_cert_dir"
    fi
  else
    cert_path=""
  fi

  local domain_sane
  domain_sane="$(sanitize_domain_name "$domain")"
  local container_name="backend-${domain_sane}"

  if ! state_csv_require_file "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    echo "[Error] Failed to initialize backend state file: $BACKEND_PORTS_FILE" >&2
    exit 1
  fi

  echo "[Info] Starting backend container '${container_name}' from image '${image}'..."
  local container_ip=""

  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
    if declare -F _domain_runtime_ensure_network >/dev/null 2>&1; then
      _domain_runtime_ensure_network "$domain" "$network_name" || _rollback_handler
    else
      ensure_network_exists "$network_name" || _rollback_handler
    fi
    # Parse docker_opts into an array to preserve quoted values
    local docker_args=()
    if [ -n "$docker_opts" ]; then
      local docker_opts_lines=""
      if ! _parse_docker_opts_capture_lines docker_opts_lines "$docker_opts" "docker options for backend '$domain'"; then
        _rollback_handler
      fi
      if [ -n "$docker_opts_lines" ]; then
        while IFS= read -r docker_arg_line; do
          docker_args+=("$docker_arg_line")
        done < <(printf '%s' "$docker_opts_lines")
      fi
    fi
    local launch_token=""
    if ! launch_token="$(_backend_launch_new_token)"; then
      echo "[Error] Failed to prepare backend launch identity." >&2
      _rollback_handler
    fi
    _add_backend_set_runtime_rollback_state "${container_name}" "$launch_token" "$domain" || _rollback_handler
    local xtrace_state="" suppress_docker_xtrace=false
    if [ -n "$docker_opts" ] && operator_visibility_is_redacted; then
      suppress_docker_xtrace=true
      xtrace_disable xtrace_state
    fi
    local -a docker_run_cmd=(docker run -d --name "${container_name}" --network "$network_name")
    if [ "${DOMAIN_CONFIG_DESIRED_STATE:-running}" = stopped ]; then
      docker_run_cmd=(docker create --name "${container_name}" --network "$network_name")
    fi
    # Bash 3 + set -u: avoid expanding empty arrays directly.
    if [ ${#docker_args[@]} -gt 0 ]; then
      docker_run_cmd+=("${docker_args[@]}")
    fi
    # Put the attempt identity last so operator labels cannot replace it.
    # Keep --cidfile available for the operator's own Docker workflow.
    _backend_launch_labels "$domain" "$launch_token" || _rollback_handler
    docker_run_cmd+=("${image}")
    local container_id=""
    if container_id="$("${docker_run_cmd[@]}" || exit "$?")"; then
      :
    else
      if [ "$suppress_docker_xtrace" = true ]; then
        xtrace_restore "$xtrace_state"
      fi
      _rollback_handler
    fi
    if [ "$suppress_docker_xtrace" = true ]; then
      xtrace_restore "$xtrace_state"
    fi
    if ! _backend_identity_inspect "$domain" "$container_id" "$launch_token"; then
      _rollback_handler
    fi
    container_ip="$(_backend_snapshot_network_ip "$network_name")"
    if [ -z "$container_ip" ] && [ "${DOMAIN_CONFIG_DESIRED_STATE:-running}" = stopped ]; then
      container_ip=127.0.0.1
    elif [ -z "$container_ip" ]; then
      echo "[Error] Failed to get IP for container '${container_name}' on network '${network_name}'." >&2
      _rollback_handler
    fi
    _backend_identity_store "$domain" "$container_id" "$launch_token" || _rollback_handler
  else
    # Dry-run mode: do not start Docker; use loopback placeholder
    container_ip="127.0.0.1"
  fi

  set_backend_docker_opts "backend:${domain}" "$docker_opts" || _rollback_handler
  state_csv_append_row_line "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" \
    "$(state_backend_ports_row_backend "${domain}" "${container_ip}:${container_port}" "${network_name}")" || _rollback_handler

  if { [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; } && [ "$expose_now" = "yes" ]; then
    if _stream_listen_in_use "$listen_port" "$protocol"; then
      local protocol_upper
      protocol_upper="$(printf '%s' "$protocol" | tr '[:lower:]' '[:upper:]')"
      echo "[Error] ${protocol_upper} port ${listen_port} is already in use by another mapping." >&2
      _rollback_handler
    fi
  fi

  # Add initial port mapping according to selected protocol (unless exposure disabled)
  if [ "$expose_now" = "yes" ]; then
    if [ "$protocol" = "tcp" ]; then
      state_csv_append_row_line "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" \
        "$(state_backend_ports_row_port "${domain}" "${listen_port}" "${container_port}" "tcp" "" "no" "off" "")" || _rollback_handler
    elif [ "$protocol" = "udp" ]; then
      state_csv_append_row_line "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" \
        "$(state_backend_ports_row_port "${domain}" "${listen_port}" "${container_port}" "udp" "" "no" "off" "")" || _rollback_handler
    elif [ "$protocol" = "https" ]; then
      state_csv_append_row_line "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" \
        "$(state_backend_ports_row_port "${domain}" "${listen_port}" "${container_port}" "https" "${cert_path}" "no" "off" "")" || _rollback_handler
    else
      # http
      [ -n "$ws" ] || ws="no"
      state_csv_append_row_line "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" \
        "$(state_backend_ports_row_port "${domain}" "${listen_port}" "${container_port}" "http" "none" "${ws}" "off" "")" || _rollback_handler
    fi
  else
    echo "[Info] Backend created without exposure. Use 'add-port' to expose HTTP/HTTPS/TCP/UDP."
  fi

  if [ "$expose_now" = "yes" ]; then
    echo "[Info] Backend for '${domain}' => ${container_ip}:${container_port} on ${network_name}; mapped ${protocol} on ${listen_port}."
    log_msg "Added backend $container_name with ${protocol}:${listen_port}"
  else
    echo "[Info] Backend for '${domain}' => ${container_ip}:${container_port} on ${network_name}; no ports exposed."
    log_msg "Added backend $container_name without exposure"
  fi

  # Optional HTTP redirect helper when creating backends with HTTPS ports interactively
  if [ "$protocol" = "https" ] && [ "$expose_now" = "yes" ]; then
    local redirect_ans="" redirect_target_port http_port_default
    http_port_default=80
    redirect_target_port="$listen_port"
    local redirect_from_ui="${redirect_pref:-}"
    local target_from_ui="${redirect_target_port_ui:-}"

    if [ -n "$redirect_from_ui" ]; then
      redirect_ans="$redirect_from_ui"
      if [ -n "$target_from_ui" ] && is_valid_port "$target_from_ui"; then
        redirect_target_port="$target_from_ui"
      fi
    elif [ "$INTERACTIVE" = true ]; then
      read_yes_no_with_default redirect_ans "Enable HTTP redirect from ${http_port_default} to https port ${redirect_target_port}? [Y/n]: " "yes"
      if [ "$redirect_ans" = "yes" ]; then
        local custom_target=""
        read_with_editing "Redirect target port [${redirect_target_port}]: " custom_target "$redirect_target_port"
        if [ -n "$custom_target" ]; then
          if is_valid_port "$custom_target"; then
            redirect_target_port="$custom_target"
          else
            echo "[Warn] Invalid port '${custom_target}', keeping ${redirect_target_port}." >&2
          fi
        fi
      fi
    fi

    if [ "$redirect_ans" = "yes" ]; then
      local prev_skip="${SKIP_UPDATE_NGINX_CONFIG:-}"
      push_skip_update_nginx_config prev_skip
      # Ensure HTTP listener exists to carry the redirect
      add_port_mapping "$domain" "$http_port_default" "$container_port" "http" "none" "no"
      set_port_redirect "$domain" "$http_port_default" "on" "301:${redirect_target_port}"
      pop_skip_update_nginx_config "$prev_skip"
    fi
  fi

  if declare -F domain_config_record_backend >/dev/null 2>&1; then
    domain_config_record_backend "$domain" "$image" "$container_port" "$network_name" "${DOMAIN_CONFIG_DESIRED_STATE:-running}" || _rollback_handler
  fi
  update_nginx_config || _rollback_handler
  end_transaction_success || _rollback_handler
  _add_backend_clear_runtime_rollback_state
}
