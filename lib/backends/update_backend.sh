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
  UPDATE_BACKEND_RUNTIME_TOKEN="${10:-}"
  UPDATE_BACKEND_RUNTIME_BACKUP_ID="${11:-}"
  if [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then
    local new_network_existed=false old_network_existed=false
    _domain_runtime_snapshot_has_network "$UPDATE_BACKEND_RUNTIME_NEW_NET" && new_network_existed=true
    _domain_runtime_snapshot_has_network "$UPDATE_BACKEND_RUNTIME_OLD_NET" && old_network_existed=true
    _domain_runtime_record "$UPDATE_BACKEND_RUNTIME_MODE" "${UPDATE_BACKEND_RUNTIME_DOMAIN:-}" \
      old_id "$UPDATE_BACKEND_RUNTIME_BACKUP_ID" old_token "${UPDATE_BACKEND_RUNTIME_OLD_TOKEN:-}" \
      name "$UPDATE_BACKEND_RUNTIME_CNAME" new_token "$UPDATE_BACKEND_RUNTIME_TOKEN" \
      old_state "${original_status:-stopped}" unmanaged "${UPDATE_BACKEND_RUNTIME_UNMANAGED:-false}" \
      old_network "$UPDATE_BACKEND_RUNTIME_OLD_NET" new_network "$UPDATE_BACKEND_RUNTIME_NEW_NET" \
      old_network_existed "$old_network_existed" new_network_existed "$new_network_existed" || return 1
    return 0
  fi
  rollback_pre_hook_add "_update_backend_runtime_rollback_if_needed"
  case "$UPDATE_BACKEND_RUNTIME_MODE" in add | replace) _backend_runtime_install_signal_traps ;; esac
}

function _update_backend_clear_runtime_rollback_state() {
  if declare -F _domain_runtime_finish_operation >/dev/null 2>&1; then
    _domain_runtime_finish_operation
  fi
  rollback_pre_hook_remove "_update_backend_runtime_rollback_if_needed"
  if [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then _backend_runtime_clear_signal_traps; fi
  unset UPDATE_BACKEND_RUNTIME_MODE
  unset UPDATE_BACKEND_RUNTIME_CNAME
  unset UPDATE_BACKEND_RUNTIME_BACKUP_CNAME
  unset UPDATE_BACKEND_RUNTIME_OLD_NET
  unset UPDATE_BACKEND_RUNTIME_NEW_NET
  unset UPDATE_BACKEND_RUNTIME_CONNECTED_NEW
  unset UPDATE_BACKEND_RUNTIME_DISCONNECTED_OLD
  unset UPDATE_BACKEND_RUNTIME_REPLACEMENT_ID
  unset UPDATE_BACKEND_RUNTIME_BACKUP_WAS_STOPPED
  unset UPDATE_BACKEND_RUNTIME_TOKEN UPDATE_BACKEND_RUNTIME_BACKUP_ID
  unset UPDATE_BACKEND_RUNTIME_DOMAIN UPDATE_BACKEND_RUNTIME_OLD_TOKEN UPDATE_BACKEND_RUNTIME_UNMANAGED
}

function _update_backend_original_snapshot() {
  local domain="${1:-}" container_id="${2:-}" token="${3:-}" unmanaged="${4:-false}"
  if [ "$unmanaged" = true ]; then
    _backend_identity_inspect_unmanaged "$domain" "$container_id"
  else
    _backend_identity_inspect "$domain" "$container_id" "$token"
  fi
}

function _update_backend_runtime_rollback_if_needed() {
  local mode="${UPDATE_BACKEND_RUNTIME_MODE:-}"
  local cname="${UPDATE_BACKEND_RUNTIME_CNAME:-}"
  local backup_cname="${UPDATE_BACKEND_RUNTIME_BACKUP_CNAME:-}"
  local old_net="${UPDATE_BACKEND_RUNTIME_OLD_NET:-}"
  local new_net="${UPDATE_BACKEND_RUNTIME_NEW_NET:-}"
  local connected_new="${UPDATE_BACKEND_RUNTIME_CONNECTED_NEW:-false}"
  local disconnected_old="${UPDATE_BACKEND_RUNTIME_DISCONNECTED_OLD:-false}"
  local backup_was_stopped="${UPDATE_BACKEND_RUNTIME_BACKUP_WAS_STOPPED:-false}"
  local launch_token="${UPDATE_BACKEND_RUNTIME_TOKEN:-}"
  local backup_id="${UPDATE_BACKEND_RUNTIME_BACKUP_ID:-}" restored_name="" failed=false
  local domain="${UPDATE_BACKEND_RUNTIME_DOMAIN:-}" old_token="${UPDATE_BACKEND_RUNTIME_OLD_TOKEN:-}"

  if [ -z "$cname" ]; then
    return 0
  fi

  case "$mode" in
  add)
    _backend_runtime_quiet_signal_traps
    _backend_launch_cleanup "$launch_token" "$domain"
    ;;
  replace)
    _backend_runtime_quiet_signal_traps
    _backend_launch_cleanup "$launch_token" "$domain" || failed=true
    if ! _backend_runtime_is_full_container_id "$backup_id"; then
      echo "[Error] Original backend container identity is unavailable; retaining rollback container '$backup_cname'." >&2
      return 1
    fi
    _update_backend_original_snapshot "$domain" "$backup_id" "$old_token" "${UPDATE_BACKEND_RUNTIME_UNMANAGED:-false}" || return 1
    if ! docker rename "$backup_id" "$cname" >/dev/null 2>&1; then
      # A repeated recovery may already have restored the original name.
      restored_name="$(docker inspect -f '{{.Name}}' "$backup_id" 2>/dev/null)" || return 1
      if [ "$restored_name" != "/$cname" ]; then
        echo "[Error] Failed to restore original backend container '$backup_id' as '$cname'; retaining the rollback container." >&2
        return 1
      fi
    fi
    if [ "$backup_was_stopped" = "true" ] && ! docker start "$backup_id" >/dev/null 2>&1; then
      echo "[Error] Failed to restart original backend container '$backup_id'; runtime rollback is incomplete." >&2
      failed=true
    fi
    [ "$failed" = false ]
    ;;
  network)
    _update_backend_original_snapshot "$domain" "$backup_id" "$old_token" "${UPDATE_BACKEND_RUNTIME_UNMANAGED:-false}" || return 1
    if [ "$disconnected_old" = "true" ] && [ -n "$old_net" ]; then
      if ! docker network connect "$old_net" "$backup_id" >/dev/null 2>&1; then
        echo "[Error] Failed to restore original network for backend '$domain'; runtime rollback is incomplete." >&2
        return 1
      fi
    fi
    if [ "$connected_new" = "true" ] && [ -n "$new_net" ]; then
      if ! docker network disconnect "$new_net" "$backup_id" >/dev/null 2>&1; then
        echo "[Error] Failed to detach replacement network for backend '$domain'; runtime rollback is incomplete." >&2
        return 1
      fi
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
    echo "[Usage] update-backend <domain> [--image img] [--container-port port] [--docker-opts opts] [--network net] [--replace-unmanaged-container full-id --image img]"
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
  local current_image="" original_id="" original_token="" original_status=""
  local replacement_container_id="" original_unmanaged=false interactive_positionals=false
  local domain_mock_runtime=false
  local DOMAIN_CONFIG_DESIRED_STATE="${DOMAIN_CONFIG_DESIRED_STATE:-}" preserve_runtime_state=false
  if [ -z "$DOMAIN_CONFIG_DESIRED_STATE" ] &&
    declare -F domain_config_runtime_enabled >/dev/null 2>&1 && domain_config_runtime_enabled; then
    preserve_runtime_state=true
  fi
  if [ "$INTERACTIVE" = true ] && [[ "${1:-}" != --* ]]; then
    interactive_positionals=true
    image="${1:-}"
    cport="${2:-}"
    docker_opts="${3:-}"
    # Only treat docker opts as provided if user actually changes them
    docker_opts_provided=false
    network="${4:-}"
    replacement_container_id="${5:-}"
  else
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --replace-unmanaged-container)
        require_option_value "$@" || return 1
        replacement_container_id="$2"
        shift 2
        ;;
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
        echo "[Usage] update-backend <domain> [--image img] [--container-port port] [--docker-opts opts] [--network net] [--replace-unmanaged-container full-id --image img]"
        return 1
        ;;
      esac
    done
  fi

  if [ "${SKIP_DOCKER_CHECKS:-false}" = true ] &&
    declare -F domain_config_runtime_enabled >/dev/null 2>&1 && domain_config_runtime_enabled; then
    domain_mock_runtime=true
    local mock_runtime_file="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/runtime/backend.csv"
    BACKEND_CONTAINER_IMAGE="$(_domain_runtime_get "$mock_runtime_file" image)" || return 1
    BACKEND_CONTAINER_STATUS="$(_domain_runtime_get "$mock_runtime_file" state stopped)" || return 1
    BACKEND_CONTAINER_ID="" BACKEND_CONTAINER_TOKEN=""
  elif [ -n "$replacement_container_id" ]; then
    if [ -z "$image" ] || ! _backend_runtime_is_full_container_id "$replacement_container_id"; then
      echo "[Error] --replace-unmanaged-container requires a full 64-character container ID and an explicit --image." >&2
      return 1
    fi
    _backend_identity_can_replace_unmanaged "$domain" || return 1
    _backend_identity_inspect_unmanaged "$domain" "$replacement_container_id" "backend-$(sanitize_domain_name "$domain")" || return 1
    original_unmanaged=true
  else
    _backend_container_snapshot "$domain" || return 1
  fi
  current_image="$BACKEND_CONTAINER_IMAGE"
  original_id="$BACKEND_CONTAINER_ID"
  original_token="$BACKEND_CONTAINER_TOKEN"
  original_status="$BACKEND_CONTAINER_STATUS"
  if [ "$preserve_runtime_state" = true ]; then
    DOMAIN_CONFIG_DESIRED_STATE=stopped
    [ "$original_status" != running ] || DOMAIN_CONFIG_DESIRED_STATE=running
  fi

  [ -z "$cport" ] && cport="$cur_port"
  [ -z "$network" ] && network="$cur_net"

  # Normalize docker opts intent in interactive mode:
  # blank means keep current, explicit sentinel means clear.
  if [ "$interactive_positionals" = true ]; then
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
  # Reject selected or saved options before creating a network or transaction.
  local new_ip="$cur_ipport" opts_to_use
  if [ "$docker_opts_provided" = true ]; then
    opts_to_use="$docker_opts"
  else
    opts_to_use="$cur_docker_opts"
  fi
  if [ -n "$opts_to_use" ]; then
    if ! opts_to_use="$(normalize_docker_opts_for_storage "$opts_to_use" "docker options for backend '$domain'" "backend")"; then
      return 1
    fi
  fi
  if [ "$docker_opts_provided" = true ] && [ "$opts_to_use" = "$cur_docker_opts" ]; then
    docker_opts_provided=false
  fi

  local final_image="${image:-$current_image}"
  if [ -n "$image" ] || [ "$docker_opts_provided" = true ]; then
    if [ -z "$final_image" ]; then
      echo "[Error] Unable to determine image for backend '$domain'. Pass --image to update-backend." >&2
      return 1
    fi
    require_valid_image_ref "$final_image" "backend '$domain'" || return 1
  fi

  if ! begin_transaction "update_backend_${domain}" "$CONFIG_DIR"; then
    return 1
  fi
  local rollback_cname="" rollback_container_id=""
  local rollback_container_was_stopped="false"
  if [ "$domain_mock_runtime" = true ]; then
    new_ip="127.0.0.1:${cport}"
    set_backend_docker_opts "backend:${domain}" "$opts_to_use" || _rollback_handler
  else
    if [ "$original_unmanaged" = true ]; then
      if ! _backend_identity_can_replace_unmanaged "$domain" ||
        ! _backend_identity_inspect_unmanaged "$domain" "$original_id" "backend-$(sanitize_domain_name "$domain")"; then
        _rollback_handler
      fi
    elif ! _backend_container_snapshot "$domain" || [ "$BACKEND_CONTAINER_ID" != "$original_id" ] ||
      [ "$BACKEND_CONTAINER_TOKEN" != "$original_token" ]; then
      echo "[Error] Backend identity changed while the update was acquiring its transaction lock." >&2
      _rollback_handler
    fi
    original_status="$BACKEND_CONTAINER_STATUS"
    if [ "$preserve_runtime_state" = true ]; then
      DOMAIN_CONFIG_DESIRED_STATE=stopped
      [ "$original_status" != running ] || DOMAIN_CONFIG_DESIRED_STATE=running
    fi
    UPDATE_BACKEND_RUNTIME_UNMANAGED="$original_unmanaged"
    UPDATE_BACKEND_RUNTIME_DOMAIN="$domain"
    UPDATE_BACKEND_RUNTIME_OLD_TOKEN="$original_token"
    if declare -F _domain_runtime_ensure_network >/dev/null 2>&1; then
      _domain_runtime_ensure_network "$domain" "$network" || _rollback_handler
    elif ! ensure_network_exists "$network"; then
      _rollback_handler
    fi

    if [ -n "$image" ] || [ "$docker_opts_provided" = true ]; then
      local launch_token=""
      if ! launch_token="$(_backend_launch_new_token)"; then
        echo "[Error] Failed to prepare backend launch identity." >&2
        _rollback_handler
      fi
      rollback_container_id="$original_id"
      if ! rollback_cname="$(_update_backend_runtime_backup_name "$cname")"; then
        echo "[Error] Failed to reserve a rollback container name for '${cname}'." >&2
        _rollback_handler
      fi
      _update_backend_set_runtime_rollback_state "replace" "$cname" "$rollback_cname" "" "" "false" "false" "" "$rollback_container_was_stopped" "$launch_token" "$rollback_container_id" || _rollback_handler
      if ! docker rename "$rollback_container_id" "$rollback_cname"; then
        echo "[Error] Failed to stage existing container '${cname}' for rollback." >&2
        _rollback_handler
      fi
      if [ "$original_status" = running ]; then
        rollback_container_was_stopped="true"
        _update_backend_set_runtime_rollback_state "replace" "$cname" "$rollback_cname" "" "" "false" "false" "" "$rollback_container_was_stopped" "$launch_token" "$rollback_container_id" || _rollback_handler
        if ! docker stop "$rollback_container_id" >/dev/null 2>&1; then
          echo "[Error] Failed to stop staged rollback container '${rollback_cname}' before replacement launch." >&2
          _rollback_handler
        fi
      fi
      # Parse docker_opts into an array to preserve quoted values
      local docker_args=()
      if [ -n "$opts_to_use" ]; then
        local docker_opts_lines=""
        if ! _parse_docker_opts_capture_lines docker_opts_lines "$opts_to_use" "docker options for backend '$domain'"; then
          _rollback_handler
        fi
        if [ -n "$docker_opts_lines" ]; then
          while IFS= read -r docker_arg_line; do
            docker_args+=("$docker_arg_line")
          done < <(printf '%s' "$docker_opts_lines")
        fi
      fi
      local xtrace_state="" suppress_docker_xtrace=false
      if [ -n "$opts_to_use" ] && operator_visibility_is_redacted; then
        suppress_docker_xtrace=true
        xtrace_disable xtrace_state
      fi
      local -a docker_run_cmd=(docker run -d --name "$cname" --network "$network")
      if [ "${DOMAIN_CONFIG_DESIRED_STATE:-running}" = stopped ]; then
        docker_run_cmd=(docker create --name "$cname" --network "$network")
      fi
      # Bash 3 + set -u: avoid expanding empty arrays directly.
      if [ ${#docker_args[@]} -gt 0 ]; then
        docker_run_cmd+=("${docker_args[@]}")
      fi
      _backend_launch_labels "$domain" "$launch_token" || _rollback_handler
      docker_run_cmd+=("$final_image")
      local replacement_id=""
      if replacement_id="$("${docker_run_cmd[@]}" || exit "$?")"; then
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
      _backend_identity_inspect "$domain" "$replacement_id" "$launch_token" || _rollback_handler
      new_ip="$(_backend_snapshot_network_ip "$network")"
      if [ -z "$new_ip" ] && [ "${DOMAIN_CONFIG_DESIRED_STATE:-running}" = stopped ]; then
        new_ip=127.0.0.1
      elif [ -z "$new_ip" ]; then
        echo "[Error] Failed to get IP for container '${cname}' on network '${network}'." >&2
        _rollback_handler
      fi
      new_ip="${new_ip}:${cport}"
      _backend_identity_store "$domain" "$replacement_id" "$launch_token" || _rollback_handler
      set_backend_docker_opts "backend:${domain}" "$opts_to_use" || _rollback_handler
    else
      if [ "$network" != "$cur_net" ]; then
        _update_backend_set_runtime_rollback_state "network" "$cname" "" "$cur_net" "$network" "false" "false" "" "false" "" "$original_id" || _rollback_handler
        local cip=""
        _backend_identity_inspect "$domain" "$original_id" "$original_token" || _rollback_handler
        cip="$(_backend_snapshot_network_ip "$network")"
        # A network change may precede a requested start. Check observed state
        # and membership, since a stopped attachment need not have an IP yet.
        if [ -z "$cip" ] && [ "$BACKEND_CONTAINER_STATUS" != running ] &&
          _backend_snapshot_has_network "$network"; then
          cip=127.0.0.1
        fi
        if [ -z "$cip" ]; then
          if docker network connect "$network" "$original_id" >/dev/null 2>&1; then
            UPDATE_BACKEND_RUNTIME_CONNECTED_NEW="true"
          fi
          _backend_identity_inspect "$domain" "$original_id" "$original_token" || _rollback_handler
          cip="$(_backend_snapshot_network_ip "$network")"
        fi
        if [ -z "$cip" ] && [ "$BACKEND_CONTAINER_STATUS" != running ] &&
          _backend_snapshot_has_network "$network"; then
          cip=127.0.0.1
        fi
        if [ -z "$cip" ]; then
          echo "[Error] Failed to connect container '${cname}' to network '${network}'." >&2
          _rollback_handler
        fi
        if docker network disconnect "$cur_net" "$original_id" >/dev/null 2>&1; then
          UPDATE_BACKEND_RUNTIME_DISCONNECTED_OLD="true"
        else
          _backend_identity_inspect "$domain" "$original_id" "$original_token" || _rollback_handler
          if _backend_snapshot_has_network "$cur_net"; then
            echo "[Error] Failed to disconnect container '${cname}' from network '${cur_net}'." >&2
            _rollback_handler
          fi
        fi
        new_ip="${cip}:${cport}"
      else
        local ip="${cur_ipport%%:*}"
        new_ip="${ip}:${cport}"
      fi
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
  # During explicit sequential migration, other legacy rows remain exactly as
  # saved, without discovering their runtime addresses or adopting their names.
  local BACKEND_IDENTITY_MIGRATION="$original_unmanaged"
  if [ "$original_unmanaged" = true ] &&
    [ "${DOMAIN_CONFIG_MUTATION_COMMAND:-}" = update-backend ] &&
    [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then
    # The outer command activates its render after this function returns.
    DOMAIN_CONFIG_BACKEND_IDENTITY_MIGRATION=true
  fi
  if declare -F domain_config_record_backend >/dev/null 2>&1; then
    local recorded_state="${DOMAIN_CONFIG_DESIRED_STATE:-}"
    if [ -z "$recorded_state" ]; then
      recorded_state=stopped
      [ "$original_status" != running ] || recorded_state=running
      if [ -n "$image" ] || [ "$docker_opts_provided" = true ]; then recorded_state=running; fi
    fi
    domain_config_record_backend "$domain" "$final_image" "$cport" "$network" "$recorded_state" || _rollback_handler
  fi
  update_nginx_config || _rollback_handler
  end_transaction_success || _rollback_handler
  _update_backend_clear_runtime_rollback_state
  if [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] && [ -n "$rollback_container_id" ] && ! _backend_runtime_container_is_absent "$rollback_container_id"; then
    if ! _update_backend_original_snapshot "$domain" "$rollback_container_id" "$original_token" "$original_unmanaged" ||
      ! remove_container_preserving_volumes "$rollback_container_id" >/dev/null 2>&1; then
      echo "[Warn] Failed to remove superseded backend container '${rollback_cname}' after commit; leaving rollback container in place." >&2
      log_msg "Warn: superseded backend container ${rollback_cname} remained after commit"
    fi
  fi
}

# Backwards compatibility wrappers
