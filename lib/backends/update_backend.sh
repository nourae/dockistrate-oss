# shellcheck shell=bash
function _update_backend_set_runtime_rollback_state() {
  UPDATE_BACKEND_RUNTIME_MODE="${1:-}"
  UPDATE_BACKEND_RUNTIME_CNAME="${2:-}"
  UPDATE_BACKEND_RUNTIME_BACKUP_CNAME="${3:-}"
  UPDATE_BACKEND_RUNTIME_OLD_NET="${4:-}"
  UPDATE_BACKEND_RUNTIME_NEW_NET="${5:-}"
  UPDATE_BACKEND_RUNTIME_CONNECTED_NEW="${6:-false}"
  UPDATE_BACKEND_RUNTIME_DISCONNECTED_OLD="${7:-false}"
  UPDATE_BACKEND_RUNTIME_REPLACEMENT_ID="${8:-}"
  UPDATE_BACKEND_RUNTIME_BACKUP_WAS_STOPPED="${9:-false}"
  rollback_pre_hook_add "_update_backend_runtime_rollback_if_needed"
}

function _update_backend_clear_runtime_rollback_state() {
  rollback_pre_hook_remove "_update_backend_runtime_rollback_if_needed"
  unset UPDATE_BACKEND_RUNTIME_MODE
  unset UPDATE_BACKEND_RUNTIME_CNAME
  unset UPDATE_BACKEND_RUNTIME_BACKUP_CNAME
  unset UPDATE_BACKEND_RUNTIME_OLD_NET
  unset UPDATE_BACKEND_RUNTIME_NEW_NET
  unset UPDATE_BACKEND_RUNTIME_CONNECTED_NEW
  unset UPDATE_BACKEND_RUNTIME_DISCONNECTED_OLD
  unset UPDATE_BACKEND_RUNTIME_REPLACEMENT_ID
  unset UPDATE_BACKEND_RUNTIME_BACKUP_WAS_STOPPED
}

function _update_backend_runtime_container_id() {
  local cname="${1:-}"
  [ -n "$cname" ] || return 0
  docker inspect -f '{{.Id}}' "$cname" 2>/dev/null || true
}

function _update_backend_runtime_rollback_if_needed() {
  local mode="${UPDATE_BACKEND_RUNTIME_MODE:-}"
  local cname="${UPDATE_BACKEND_RUNTIME_CNAME:-}"
  local backup_cname="${UPDATE_BACKEND_RUNTIME_BACKUP_CNAME:-}"
  local old_net="${UPDATE_BACKEND_RUNTIME_OLD_NET:-}"
  local new_net="${UPDATE_BACKEND_RUNTIME_NEW_NET:-}"
  local connected_new="${UPDATE_BACKEND_RUNTIME_CONNECTED_NEW:-false}"
  local disconnected_old="${UPDATE_BACKEND_RUNTIME_DISCONNECTED_OLD:-false}"
  local replacement_id="${UPDATE_BACKEND_RUNTIME_REPLACEMENT_ID:-}"
  local backup_was_stopped="${UPDATE_BACKEND_RUNTIME_BACKUP_WAS_STOPPED:-false}"
  local current_replacement_id=""

  if [ -z "$cname" ]; then
    return 0
  fi

  case "$mode" in
  add)
    if container_exists "$cname"; then
      remove_container_and_anonymous_volumes "$cname" >/dev/null 2>&1 || true
    fi
    ;;
  replace)
    if container_exists "$cname"; then
      current_replacement_id="$(_update_backend_runtime_container_id "$cname")"
    fi
    if [ -n "$replacement_id" ] && [ "$current_replacement_id" = "$replacement_id" ]; then
      remove_container_and_anonymous_volumes "$cname" >/dev/null 2>&1 || true
    fi
    if [ -n "$backup_cname" ] && container_exists "$backup_cname"; then
      if docker rename "$backup_cname" "$cname" >/dev/null 2>&1; then
        if [ "$backup_was_stopped" = "true" ]; then
          docker start "$cname" >/dev/null 2>&1 || true
        fi
      fi
    fi
    ;;
  network)
    if [ "$disconnected_old" = "true" ] && [ -n "$old_net" ]; then
      docker network connect "$old_net" "$cname" >/dev/null 2>&1 || true
    fi
    if [ "$connected_new" = "true" ] && [ -n "$new_net" ]; then
      docker network disconnect "$new_net" "$cname" >/dev/null 2>&1 || true
    fi
    ;;
  esac
}

function _update_backend_runtime_backup_name() {
  local cname="${1:-}"
  local suffix=0 candidate=""
  [ -n "$cname" ] || return 1

  while [ "$suffix" -lt 100 ]; do
    if [ "$suffix" -eq 0 ]; then
      candidate="${cname}-rollback-$$"
    else
      candidate="${cname}-rollback-$$-${suffix}"
    fi
    if ! container_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    suffix=$((suffix + 1))
  done

  return 1
}

_UPDATE_BACKEND_REWRITE_DOMAIN=""
_UPDATE_BACKEND_REWRITE_BACKEND_UPSTREAM=""
_UPDATE_BACKEND_REWRITE_NETWORK=""
_UPDATE_BACKEND_REWRITE_BACKEND_APPLIED="no"
_UPDATE_BACKEND_REWRITE_OLD_UPSTREAM_PORT=""
_UPDATE_BACKEND_REWRITE_NEW_UPSTREAM_PORT=""

function _update_backend_rewrite_backend_row_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "backend" ] &&
    [ "$STATE_BP_DOMAIN" = "${_UPDATE_BACKEND_REWRITE_DOMAIN:-}" ]; then
    CSV_FIELDS[2]="${_UPDATE_BACKEND_REWRITE_BACKEND_UPSTREAM:-}"
    CSV_FIELDS[3]="${_UPDATE_BACKEND_REWRITE_NETWORK:-}"
    _UPDATE_BACKEND_REWRITE_BACKEND_APPLIED="yes"
  fi
  return 0
}

function _update_backend_rewrite_port_upstream_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
    [ "$STATE_BP_DOMAIN" = "${_UPDATE_BACKEND_REWRITE_DOMAIN:-}" ] &&
    [ "$STATE_BP_UPSTREAM_PORT" = "${_UPDATE_BACKEND_REWRITE_OLD_UPSTREAM_PORT:-}" ]; then
    CSV_FIELDS[7]="${_UPDATE_BACKEND_REWRITE_NEW_UPSTREAM_PORT:-}"
  fi
  return 0
}

function update_backend() {
  local domain="${1:-}"
  shift || true

  if [ -z "$domain" ]; then
    echo "[Usage] update-backend <domain> [--image img] [--container-port port] [--docker-opts opts] [--network net]"
    exit 1
  fi

  resolve_backend_domain domain "$domain" true

  # Ensure backend exists for updates
  if ! backend_exists "$domain"; then
    echo "[Error] Backend '$domain' not found." >&2
    exit 1
  fi

  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] Backend configuration file not found." >&2
    exit 1
  }
  local line="" line_no=0
  local cur_ipport="" cur_net=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      continue
    fi
    if [ "$STATE_BP_RECORD_TYPE" = "backend" ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
      cur_ipport="$STATE_BP_BACKEND_UPSTREAM"
      cur_net="$STATE_BP_NETWORK"
      break
    fi
  done <"$BACKEND_PORTS_FILE"
  [ -n "$cur_ipport" ] || {
    echo "[Error] Backend '$domain' not found." >&2
    exit 1
  }

  [ -z "$cur_net" ] && cur_net="$DEFAULT_NETWORK"
  local cur_port="${cur_ipport##*:}"
  local old_port="$cur_port"
  local cur_docker_opts
  cur_docker_opts="$(get_backend_docker_opts "backend:${domain}")"

  local image="" cport="" docker_opts="" network="" docker_opts_provided=false
  local current_image
  current_image="$(get_backend_image "$domain")"
  if [ "$INTERACTIVE" = true ]; then
    image="${1:-}"
    cport="${2:-}"
    docker_opts="${3:-}"
    # Only treat docker opts as provided if user actually changes them
    docker_opts_provided=false
    network="${4:-}"
  else
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --image)
        require_option_value "$@" || return 1
        image="$2"
        shift 2
        ;;
      --container-port)
        require_option_value "$@" || return 1
        cport="$2"
        shift 2
        ;;
      --docker-opts)
        require_option_value "$@" || return 1
        docker_opts="$2"
        docker_opts_provided=true
        shift 2
        ;;
      --network)
        require_option_value "$@" || return 1
        network="$2"
        shift 2
        ;;
      *)
        echo "[Usage] update-backend <domain> [--image img] [--container-port port] [--docker-opts opts] [--network net]"
        return 1
        ;;
      esac
    done
  fi

  [ -z "$cport" ] && cport="$cur_port"
  [ -z "$network" ] && network="$cur_net"

  # Normalize docker opts intent in interactive mode:
  # blank means keep current, explicit sentinel means clear.
  if [ "$INTERACTIVE" = true ]; then
    if [ "$docker_opts" = "__DOCKER_OPTS_CLEAR__" ]; then
      docker_opts_provided=true
      docker_opts=""
    elif [ -z "$docker_opts" ]; then
      docker_opts_provided=false
      docker_opts="$cur_docker_opts"
    else
      # If same as current, treat as not provided to avoid unnecessary restart
      if [ "$docker_opts" = "$cur_docker_opts" ]; then
        docker_opts_provided=false
      else
        docker_opts_provided=true
      fi
    fi
  fi

  # Validate provided values when present
  if [ -n "$image" ]; then ensure_valid_or_prompt image "$image" "image" "" is_valid_image_ref; fi
  ensure_valid_or_prompt cport "$cport" "container_port" "$cur_port" is_valid_port
  ensure_valid_or_prompt network "$network" "network" "$cur_net" is_valid_network_name

  local port_changed=false
  if [ "$cport" != "$old_port" ]; then
    port_changed=true
  fi

  local cname="backend-$(sanitize_domain_name "$domain")"
  if ! begin_transaction "update_backend_${domain}" "$CONFIG_DIR"; then
    return 1
  fi
  if ! ensure_network_exists "$network"; then
    _rollback_handler
  fi

  local new_ip="$cur_ipport" opts_to_use
  if [ "$docker_opts_provided" = true ]; then
    opts_to_use="$docker_opts"
  else
    opts_to_use="$cur_docker_opts"
  fi
  if [ -n "$opts_to_use" ]; then
    if ! opts_to_use="$(normalize_docker_opts_for_storage "$opts_to_use" "docker options for backend '$domain'" "backend")"; then
      _rollback_handler
    fi
  fi
  if [ "$docker_opts_provided" = true ] && [ "$opts_to_use" = "$cur_docker_opts" ]; then
    docker_opts_provided=false
  fi

  local final_image
  if [ -n "$image" ]; then
    final_image="$image"
  else
    final_image="$current_image"
  fi

  local rollback_cname=""
  local rollback_container_was_stopped="false"
  if [ -n "$image" ] || [ "$docker_opts_provided" = true ]; then
    local replacement_container_id=""
    if [ -z "$final_image" ]; then
      echo "[Error] Unable to determine image for backend '$domain'. Pass --image to update-backend." >&2
      _rollback_handler
    fi
    if container_exists "$cname"; then
      if ! rollback_cname="$(_update_backend_runtime_backup_name "$cname")"; then
        echo "[Error] Failed to reserve a rollback container name for '${cname}'." >&2
        _rollback_handler
      fi
      if ! docker rename "$cname" "$rollback_cname"; then
        echo "[Error] Failed to stage existing container '${cname}' for rollback." >&2
        _rollback_handler
      fi
      _update_backend_set_runtime_rollback_state "replace" "$cname" "$rollback_cname" "" "" "false" "false" "" "$rollback_container_was_stopped"
      if container_running "$rollback_cname"; then
        if ! docker stop "$rollback_cname" >/dev/null 2>&1; then
          echo "[Error] Failed to stop staged rollback container '${rollback_cname}' before replacement launch." >&2
          _rollback_handler
        fi
        rollback_container_was_stopped="true"
        _update_backend_set_runtime_rollback_state "replace" "$cname" "$rollback_cname" "" "" "false" "false" "" "$rollback_container_was_stopped"
      fi
    else
      _update_backend_set_runtime_rollback_state "add" "$cname" "" "" "" "false" "false"
    fi
    # Parse docker_opts into an array to preserve quoted values
    local docker_args=()
    if [ -n "$opts_to_use" ]; then
      local docker_opts_lines=""
      if ! docker_opts_lines="$(_parse_docker_opts_to_lines "$opts_to_use" "docker options for backend '$domain'")"; then
        _rollback_handler
      fi
      if [ -n "$docker_opts_lines" ]; then
        while IFS= read -r docker_arg_line; do
          docker_args+=("$docker_arg_line")
        done <<<"$docker_opts_lines"
      fi
    fi
    local xtrace_state="" suppress_docker_xtrace=false
    if [ -n "$opts_to_use" ] && operator_visibility_is_redacted; then
      suppress_docker_xtrace=true
      xtrace_disable xtrace_state
    fi
    local -a docker_run_cmd=(docker run -d --name "$cname" --network "$network")
    # Bash 3 + set -u: avoid expanding empty arrays directly.
    if [ ${#docker_args[@]} -gt 0 ]; then
      docker_run_cmd+=("${docker_args[@]}")
    fi
    docker_run_cmd+=("$final_image")
    replacement_container_id="$("${docker_run_cmd[@]}")"
    if [ "$suppress_docker_xtrace" = true ]; then
      xtrace_restore "$xtrace_state"
    fi
    if [ -z "$replacement_container_id" ]; then
      replacement_container_id="$(_update_backend_runtime_container_id "$cname")"
    fi
    if [ -n "$rollback_cname" ]; then
      _update_backend_set_runtime_rollback_state "replace" "$cname" "$rollback_cname" "" "" "false" "false" "$replacement_container_id" "$rollback_container_was_stopped"
    fi
    new_ip="$(get_container_network_ip "$cname" "$network")"
    if [ -z "$new_ip" ]; then
      echo "[Error] Failed to get IP for container '${cname}' on network '${network}'." >&2
      _rollback_handler
    fi
    new_ip="${new_ip}:${cport}"
    set_backend_docker_opts "backend:${domain}" "$opts_to_use"
  else
    if [ "$network" != "$cur_net" ]; then
      _update_backend_set_runtime_rollback_state "network" "$cname" "" "$cur_net" "$network" "false" "false"
      if container_exists "$cname"; then
        local cip
        cip="$(get_container_network_ip "$cname" "$network")"
        if [ -z "$cip" ]; then
          if docker network connect "$network" "$cname" >/dev/null 2>&1; then
            UPDATE_BACKEND_RUNTIME_CONNECTED_NEW="true"
          fi
          if [ -z "$cip" ]; then
            cip="$(get_container_network_ip "$cname" "$network")"
          fi
        fi
        if [ -z "$cip" ] || [[ "$cip" == "<no"* ]]; then
          echo "[Error] Failed to connect container '${cname}' to network '${network}'." >&2
          _rollback_handler
        fi
        if [ "$cur_net" != "$network" ]; then
          if docker network disconnect "$cur_net" "$cname" >/dev/null 2>&1; then
            UPDATE_BACKEND_RUNTIME_DISCONNECTED_OLD="true"
          elif container_attached_to_network "$cname" "$cur_net"; then
            echo "[Error] Failed to disconnect container '${cname}' from network '${cur_net}'." >&2
            _rollback_handler
          fi
        fi
        new_ip="${cip}:${cport}"
      else
        echo "[Error] Container '$cname' not found." >&2
        _rollback_handler
      fi
    else
      local ip="${cur_ipport%%:*}"
      new_ip="${ip}:${cport}"
    fi
  fi

  _UPDATE_BACKEND_REWRITE_DOMAIN="$domain"
  _UPDATE_BACKEND_REWRITE_BACKEND_UPSTREAM="$new_ip"
  _UPDATE_BACKEND_REWRITE_NETWORK="$network"
  _UPDATE_BACKEND_REWRITE_BACKEND_APPLIED="no"
  if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _update_backend_rewrite_backend_row_cb; then
    return 1
  fi

  if [ "$port_changed" = true ]; then
    _UPDATE_BACKEND_REWRITE_OLD_UPSTREAM_PORT="$old_port"
    _UPDATE_BACKEND_REWRITE_NEW_UPSTREAM_PORT="$cport"
    if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _update_backend_rewrite_port_upstream_cb; then
      return 1
    fi
  fi

  echo "[Info] Backend '${domain}' updated."
  log_msg "Updated backend $cname"
  update_nginx_config
  end_transaction_success
  _update_backend_clear_runtime_rollback_state
  if [ -n "$rollback_cname" ] && container_exists "$rollback_cname"; then
    if ! remove_container_preserving_volumes "$rollback_cname" >/dev/null 2>&1; then
      echo "[Warn] Failed to remove superseded backend container '${rollback_cname}' after commit; leaving rollback container in place." >&2
      log_msg "Warn: superseded backend container ${rollback_cname} remained after commit"
    fi
  fi
}

# Backwards compatibility wrappers
