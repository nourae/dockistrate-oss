# shellcheck shell=bash

function _domain_config_domain_selected() {
  [ -z "${DOMAIN_CONFIG_SELECTED_FILE:-}" ] || grep -Fx -- "$1" "$DOMAIN_CONFIG_SELECTED_FILE" >/dev/null
}

function domain_config_record_backend() {
  local domain="${1:-}" image="${2:-}" port="${3:-}" network="${4:-}" state="${5:-running}"
  local dir="" file=""
  if ! domain_config_runtime_enabled &&
    { ! declare -F domain_config_active >/dev/null 2>&1 || ! domain_config_active; }; then
    return 0
  fi
  is_valid_domain "$domain" && [ "$domain" = "$(normalize_domain "$domain")" ] || return 1
  case "$state" in running | stopped) ;; *) return 1 ;; esac
  dir="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/runtime"
  runtime_state_path_guard_if_declared "$dir" "backend runtime metadata" || return 1
  (umask 077; mkdir -p "$dir") || return 1
  file="$dir/backend.csv"
  _domain_runtime_put "$file" image "$image" || return 1
  _domain_runtime_put "$file" container_port "$port" || return 1
  _domain_runtime_put "$file" network "$network" || return 1
  _domain_runtime_put "$file" state "$state" || return 1
  _tighten_file_permissions "$file" 600 || return 1
  domain_config_record_observed_backend "$domain"
}

function domain_config_record_observed_backend() {
  local domain="$1" dir="${DOMAINS_DIR:-${STATE_DIR}/domains}/$1/runtime" network="" address=""
  [ "${SKIP_DOCKER_CHECKS:-false}" != true ] || return 0
  _backend_container_snapshot "$domain" || return 1
  network="$(_domain_runtime_get "$dir/backend.csv" network "${DEFAULT_NETWORK:-dockistrate-net}")" || return 1
  address="$(_backend_snapshot_network_ip "$network")" || return 1
  domain_config_record_observed_snapshot "$domain" "$network" "$address"
}

# The caller supplies one already-verified snapshot and its selected network.
# Recording it must not inspect Docker again or substitute another network.
function domain_config_record_observed_snapshot() {
  local domain="$1" network="$2" address="${3:-}" dir="" file="" temporary=""
  if ! domain_config_runtime_enabled &&
    { ! declare -F domain_config_active >/dev/null 2>&1 || ! domain_config_active; }; then return 0; fi
  is_valid_domain "$domain" && [ "$domain" = "$(normalize_domain "$domain")" ] &&
    is_valid_network_name "$network" || return 1
  [ -z "$address" ] || is_valid_ipv4 "$address" || return 1
  _backend_runtime_is_full_container_id "${BACKEND_CONTAINER_ID:-}" &&
    _backend_identity_valid_token "${BACKEND_CONTAINER_TOKEN:-}" || return 1
  dir="${DOMAINS_DIR:-${STATE_DIR}/domains}/$domain/runtime"; file="$dir/observed.csv"
  runtime_state_path_guard_if_declared "$file" "observed backend identity" || return 1
  (umask 077; mkdir -p "$dir") || return 1
  make_temp_for_file temporary "$file" || return 1
  if ! {
    if [ "${DOMAIN_CONFIG_RECOVERING_JOURNAL:-false}" = true ] && [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" = true ] &&
      [ "$(state_schema_read_marker_readonly)" -lt 3 ]; then
      # Healing the address of an old rollback must remain readable by its
      # schema-2 installation until the explicit storage conversion commits.
      printf 'key,value\n' &&
        csv_join_row container_id "$BACKEND_CONTAINER_ID" &&
        csv_join_row ownership_token "$BACKEND_CONTAINER_TOKEN" &&
        csv_join_row image "${BACKEND_CONTAINER_IMAGE:-}" &&
        csv_join_row image_id "${BACKEND_CONTAINER_IMAGE_ID:-}" &&
        csv_join_row state "${BACKEND_CONTAINER_STATUS:-}" &&
        csv_join_row network "$network" && csv_join_row address "$address"
    else
      printf '%s\n' 'container_id,ownership_token,image,image_id,state,network,address' &&
        csv_join_row "$BACKEND_CONTAINER_ID" "$BACKEND_CONTAINER_TOKEN" "${BACKEND_CONTAINER_IMAGE:-}" \
          "${BACKEND_CONTAINER_IMAGE_ID:-}" "${BACKEND_CONTAINER_STATUS:-}" "$network" "$address"
    fi
  } >"$temporary" || ! finalize_temp_file_with_mode "$file" "$temporary" 600; then
    rm -f "$temporary"
    return 1
  fi
}

function domain_config_backend_stopped() {
  local domain="${1:-}" file=""
  domain_config_runtime_enabled ||
    { declare -F domain_config_active >/dev/null 2>&1 && domain_config_active; } || return 1
  file="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/runtime/backend.csv"
  [ -f "$file" ] || return 1
  [ "$(_domain_runtime_get "$file" state)" = stopped ]
}

function _domain_runtime_record_current_state() {
  local domain="$1" desired="$2" file="" image="" port="" network="" row="" line_no=0
  image="${BACKEND_CONTAINER_IMAGE:-}"
  file="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/runtime/backend.csv"
  if [ -f "$file" ]; then
    [ -n "$image" ] || image="$(_domain_runtime_get "$file" image)" || return 1
    port="$(_domain_runtime_get "$file" container_port)" || return 1
    network="$(_domain_runtime_get "$file" network)" || return 1
  fi
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      line_no=$((line_no + 1)); [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$row" || return 1
      if [ "$STATE_BP_RECORD_TYPE" = backend ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
        port="${STATE_BP_BACKEND_UPSTREAM##*:}"
        network="$STATE_BP_NETWORK"
        break
      fi
    done <"$BACKEND_PORTS_FILE"
  fi
  domain_config_record_backend "$domain" "$image" "$port" "$network" "$desired"
}

function domain_config_backend_set_state() {
  local domain="$1" state="$2" operation="${3:-$2}" old_state="stopped" started=false
  local id="" token="" backup_reason=""
  case "$state" in running | stopped) ;; *) return 1 ;; esac
  _config_begin_transaction_if_needed started "backend_${operation}_${domain}" || return 1
  if [ "${SKIP_DOCKER_CHECKS:-false}" != true ]; then
    _backend_container_snapshot "$domain" || return 1
    id="$BACKEND_CONTAINER_ID" token="$BACKEND_CONTAINER_TOKEN"
    [ "$BACKEND_CONTAINER_STATUS" != running ] || old_state=running
    _domain_runtime_record state "$domain" old_id "$id" old_token "$token" old_state "$old_state" || return 1
    if [ "$operation" = restart ]; then
      docker restart "$id" >/dev/null || return 1
    elif [ "$state" = running ] && [ "$old_state" != running ]; then
      docker start "$id" >/dev/null || return 1
    elif [ "$state" = stopped ] && [ "$old_state" = running ]; then
      docker stop "$id" >/dev/null || return 1
    fi
    _backend_identity_inspect "$domain" "$id" "$token" || return 1
    if [ "$state" = running ]; then
      [ "$BACKEND_CONTAINER_STATUS" = running ] || return 1
    else
      [ "$BACKEND_CONTAINER_STATUS" != running ] || return 1
    fi
  fi
  _domain_runtime_record_current_state "$domain" "$state" || return 1
  _domain_runtime_finish_operation
  update_nginx_config || return 1
  case "$operation" in
  restart) backup_reason="RestartBackend_${domain}" ;;
  running) backup_reason="StartBackend_${domain}" ;;
  stopped) backup_reason="StopBackend_${domain}" ;;
  esac
  # The outer domain transaction publishes editable/applied state after this
  # operation returns. Queue its backup even when the container address stays
  # unchanged; create_backup flushes only after that final model is published.
  create_backup "" "$backup_reason" || return 1
  _config_end_transaction_if_started "$started"
}

function _domain_runtime_absent_backend_is_replaceable() {
  local domain="$1"
  _backend_identity_load "$domain" || return 1
  _backend_runtime_container_is_absent "$BACKEND_IDENTITY_ID" || return 1
  _backend_cleanup_snapshot "$domain" || return 1
  [ -z "${BACKEND_CONTAINER_ID:-}" ]
}

function _domain_runtime_launch_missing_backend() {
  local domain="$1" image="$2" port="$3" network="$4" desired="$5" options="$6"
  local token="" parsed="" argument="" id="" ip="" cname="backend-$(sanitize_domain_name "$1")"
  local -a docker_run_cmd=()
  _domain_runtime_absent_backend_is_replaceable "$domain" || return 1
  _domain_runtime_ensure_network "$domain" "$network" || return 1
  token="$(_backend_launch_new_token)" || return 1
  _domain_runtime_record add "$domain" name "$cname" new_token "$token" || return 1
  if [ "$desired" = stopped ]; then
    docker_run_cmd=(docker create --name "$cname" --network "$network")
  else
    docker_run_cmd=(docker run -d --name "$cname" --network "$network")
  fi
  _parse_docker_opts_capture_lines parsed "$options" "backend $domain" || return 1
  if [ -n "$parsed" ]; then
    while IFS= read -r argument; do docker_run_cmd+=("$argument"); done < <(printf '%s' "$parsed")
  fi
  _backend_launch_labels "$domain" "$token" || return 1
  docker_run_cmd+=("$image")
  local trace_state="" hide_trace=false
  if [ -n "$options" ] && operator_visibility_is_redacted; then
    hide_trace=true; xtrace_disable trace_state
  fi
  if id="$("${docker_run_cmd[@]}")"; then
    [ "$hide_trace" != true ] || xtrace_restore "$trace_state"
  else
    [ "$hide_trace" != true ] || xtrace_restore "$trace_state"
    return 1
  fi
  _backend_identity_inspect "$domain" "$id" "$token" || return 1
  ip="$(_backend_snapshot_network_ip "$network")" || return 1
  if [ "$desired" = stopped ]; then
    ip=127.0.0.1
  else
    [ "$BACKEND_CONTAINER_STATUS" = running ] && [ -n "$ip" ] || return 1
  fi
  _backend_identity_store "$domain" "$id" "$token" || return 1
  set_backend_docker_opts "backend:$domain" "$options" || return 1
  local _UPDATE_BACKEND_REWRITE_DOMAIN="$domain" _UPDATE_BACKEND_REWRITE_BACKEND_UPSTREAM="$ip:$port"
  local _UPDATE_BACKEND_REWRITE_NETWORK="$network" _UPDATE_BACKEND_REWRITE_BACKEND_APPLIED=no
  csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _update_backend_rewrite_backend_row_cb || return 1
  domain_config_record_backend "$domain" "$image" "$port" "$network" "$desired" || return 1
  _domain_runtime_finish_operation
}

function domain_config_reconcile_backends() {
  local candidate="${1:-}" dir="" domain="" role="" image="" port="" network="" desired="" options=""
  local prior_image="" prior_port="" prior_network="" prior_options="" prior_state="" row="" line_no=0 runtime_file=""
  local SKIP_UPDATE_NGINX_CONFIG=true INTERACTIVE=false DOMAIN_CONFIG_DESIRED_STATE="running"
  [ -d "$candidate" ] || return 1
  transaction_is_active || return 1
  domain_config_preflight_mtls "$candidate" || return 1
  domain_config_runtime_prepare || return 1
  for dir in "$candidate"/*; do
    [ -d "$dir/config" ] || continue
    domain="${dir##*/}"
    _domain_config_domain_selected "$domain" || continue
    role="$(domain_config_get "$dir/config" domain.csv role)" || return 1
    [ "$role" = backend ] || continue
    image="$(domain_config_get "$dir/config" backend.csv image)" || return 1
    port="$(domain_config_get "$dir/config" backend.csv container_port)" || return 1
    network="$(domain_config_get "$dir/config" backend.csv network "${DEFAULT_NETWORK:-dockistrate-net}")" || return 1
    desired="$(domain_config_get "$dir/config" backend.csv state running)" || return 1
    options="$(domain_config_docker_options "$dir/config")" || return 1
    DOMAIN_CONFIG_DESIRED_STATE="$desired"
    if ! backend_exists "$domain"; then
      add_backend "$domain" "$image" "$port" http --no-expose --network "$network" --docker-opts "$options" || return 1
      continue
    fi
    prior_port="" prior_network="" prior_image="" prior_state=""
    line_no=0
    while IFS= read -r row || [ -n "$row" ]; do
      line_no=$((line_no + 1)); [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$row" || return 1
      if [ "$STATE_BP_RECORD_TYPE" = backend ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
        prior_port="${STATE_BP_BACKEND_UPSTREAM##*:}" prior_network="$STATE_BP_NETWORK"
        break
      fi
    done <"$BACKEND_PORTS_FILE"
    runtime_file="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/runtime/backend.csv"
    if [ "${SKIP_DOCKER_CHECKS:-false}" = true ]; then
      if [ -f "$runtime_file" ]; then
        prior_image="$(_domain_runtime_get "$runtime_file" image)" || return 1
        prior_state="$(_domain_runtime_get "$runtime_file" state stopped)" || return 1
      fi
      # Mock mode still persists the exact candidate, without adopting Docker.
      domain_config_record_backend "$domain" "$image" "$port" "$network" "$desired" || return 1
      continue
    fi
    local snapshot_status=0
    _backend_container_snapshot "$domain" 2>/dev/null || snapshot_status=$?
    if [ "$snapshot_status" -ne 0 ]; then
      if [ "$snapshot_status" -eq 2 ] && _domain_runtime_absent_backend_is_replaceable "$domain"; then
        printf '[Info] Recreating absent managed backend: %s.\n' "$domain"
        _domain_runtime_launch_missing_backend "$domain" "$image" "$port" "$network" "$desired" "$options" || return 1
        continue
      fi
      printf '[Error] Cannot verify managed backend ownership for %s.\n' "$domain" >&2
      return 1
    fi
    prior_image="$BACKEND_CONTAINER_IMAGE"
    prior_state=stopped
    [ "$BACKEND_CONTAINER_STATUS" != running ] || prior_state=running
    prior_options="$(get_backend_docker_opts "backend:${domain}")" || return 1
    if [ "$network" = "$prior_network" ] && [ "$image" = "$prior_image" ] &&
      [ "$options" = "$prior_options" ] && ! _domain_runtime_snapshot_has_network "$network"; then
      local attach_id="$BACKEND_CONTAINER_ID" attach_token="$BACKEND_CONTAINER_TOKEN"
      _domain_runtime_ensure_network "$domain" "$network" || return 1
      _domain_runtime_record network "$domain" old_id "$attach_id" old_token "$attach_token" \
        old_network "" old_network_existed false new_network "$network" new_network_existed false || return 1
      docker network connect "$network" "$attach_id" || return 1
      _domain_runtime_finish_operation
      _backend_identity_inspect "$domain" "$attach_id" "$attach_token" || return 1
    fi
    local -a changes=()
    [ "$image" = "$prior_image" ] || changes+=(--image "$image")
    [ "$port" = "$prior_port" ] || changes+=(--container-port "$port")
    [ "$network" = "$prior_network" ] || changes+=(--network "$network")
    [ "$options" = "$prior_options" ] || changes+=(--docker-opts "$options")
    if [ "${#changes[@]}" -gt 0 ]; then
      update_backend "$domain" "${changes[@]}" || return 1
    fi
    _backend_container_snapshot "$domain" || return 1
    prior_state=stopped
    [ "$BACKEND_CONTAINER_STATUS" != running ] || prior_state=running
    if [ "$prior_state" != "$desired" ]; then
      domain_config_backend_set_state "$domain" "$desired" || return 1
    fi
    domain_config_record_backend "$domain" "$image" "$port" "$network" "$desired" || return 1
  done
  domain_config_provision_mtls "$candidate"
}
