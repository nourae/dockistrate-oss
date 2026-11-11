# shellcheck shell=bash

function domain_config_runtime_preflight() {
  local candidate="$1" path="" domain="" image="" network="" port="" name="" occupants="" occupant="" status=0
  _domain_runtime_preflight_proxy "$candidate" || return 1
  for path in "$candidate"/*; do
    [ -d "$path/config" ] || continue
    domain="${path##*/}"
    _domain_config_domain_selected "$domain" || continue
    [ "$(domain_config_get "$path/config" domain.csv role)" = backend ] || continue
    image="$(domain_config_get "$path/config" backend.csv image)" || return 1
    network="$(domain_config_get "$path/config" backend.csv network "${DEFAULT_NETWORK:-dockistrate-net}")" || return 1
    port="$(domain_config_get "$path/config" backend.csv container_port)" || return 1
    is_valid_image_ref "$image" && is_valid_network_name "$network" && is_valid_port "$port" || return 1
    domain_config_docker_options "$path/config" >/dev/null || return 1
    [ "${SKIP_DOCKER_CHECKS:-false}" != true ] || continue
    if backend_exists "$domain"; then
      status=0
      _backend_container_snapshot "$domain" 2>/dev/null || status=$?
      if [ "$status" -eq 0 ]; then continue; fi
      if [ "$status" -eq 2 ] && _domain_runtime_absent_backend_is_replaceable "$domain"; then continue; fi
      printf '[Error] Backend ownership preflight failed for %s.\n' "$domain" >&2
      return 1
    fi
    _backend_identity_read "$domain" true || return 1
    if [ "$BACKEND_IDENTITY_FOUND" -ne 0 ]; then
      printf '[Error] Saved backend identity exists without an applied backend row for %s; explicit cleanup or repair is required.\n' "$domain" >&2
      return 1
    fi
    name="backend-$(sanitize_domain_name "$domain")"
    occupants="$(docker ps -a --no-trunc --filter "name=^/${name}$" --format '{{.Names}}')" || return 1
    while IFS= read -r occupant; do
      if [ "$occupant" = "$name" ]; then
        printf '[Error] Backend name is already occupied: %s.\n' "$name" >&2
        return 1
      fi
    done <<<"$occupants"
  done
}

function _domain_runtime_preflight_proxy() {
  local candidate="$1" path="" rows="" row="" port="" protocol="" transport="" http3="" binding="" current="" desired=$'\n'
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ "${SKIP_DOCKER_CHECKS:-false}" != true ] || return 0
  ensure_no_nginx_container_conflict apply-domain-config || return 1
  if nginx_container_is_managed && container_running "$NGINX_CONTAINER_NAME"; then
    current="$(container_published_port_bindings "$NGINX_CONTAINER_NAME" | xargs)" || return 1
  fi
  # All accepted domains share this proxy, even when the apply selection is one
  # domain. Validate its complete publication set while allowing its own ports.
  for path in "$candidate"/*; do
    [ -d "$path/config" ] || continue
    rows="$(_domain_csv_rows "$path/config/ports.csv")" || return 1
    [ -n "$rows" ] || continue
    while IFS= read -r row; do
      csv_parse_line "$row" || return 1
      port="${CSV_FIELDS[0]}"; protocol="${CSV_FIELDS[2]}"; transport=tcp
      [ "$protocol" != udp ] || transport=udp
      binding="$port/$transport"
      case "$desired" in *$'\n'"$binding"$'\n'*) ;; *) desired+="$binding"$'\n' ;; esac
      if [ "$protocol" = https ]; then
        if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
          http3="$(domain_config_port_option "$path/config" "$port" "$protocol" http3_enabled off)" || return 1
        else
          http3="${CSV_FIELDS[8]}"
        fi
        if [ "$http3" = on ]; then
          binding="$port/udp"
          case "$desired" in *$'\n'"$binding"$'\n'*) ;; *) desired+="$binding"$'\n' ;; esac
        fi
      fi
    done <<<"$rows"
  done
  while IFS= read -r binding; do
    [ -n "$binding" ] || continue
    case " $current " in *" $binding "*) continue ;; esac
    assert_host_port_available_or_fail "${binding%/*}" "${binding##*/}" "" "" true || return 1
  done <<<"$desired"
}

# Restoring a previously running container may allocate a different address.
# Repair only affected routes before reloading the old proxy configuration.
function _domain_runtime_refresh_recovered_routes() {
  local journal="$1" operation="" mode="" domain="" seen=$'\n' row="" number=0 network="" prior="" ip="" changed=false unmanaged=false
  [ "${SKIP_DOCKER_CHECKS:-false}" != true ] && [ -f "${BACKEND_PORTS_FILE:-}" ] || return 0
  for operation in "$journal/operations/"*.csv; do
    [ -f "$operation" ] || continue
    [ "$(_domain_runtime_get "$operation" ready no)" = yes ] || continue
    mode="$(_domain_runtime_get "$operation" mode)" || return 1
    case "$mode" in replace | network | state) ;; *) continue ;; esac
    domain="$(_domain_runtime_get "$operation" domain)" || return 1
    case "$seen" in *$'\n'"$domain"$'\n'*) continue ;; esac
    seen+="$domain"$'\n'
    unmanaged="$(_domain_runtime_get "$operation" unmanaged false)" || return 1
    if [ "$unmanaged" = true ]; then
      _backend_identity_inspect_unmanaged "$domain" "$(_domain_runtime_get "$operation" old_id)" || return 1
    else
      _backend_container_snapshot "$domain" || return 1
    fi
    [ "$BACKEND_CONTAINER_STATUS" = running ] || continue
    prior=""; network=""; number=0
    while IFS= read -r row || [ -n "$row" ]; do
      number=$((number + 1)); [ "$number" -eq 1 ] && continue
      state_backend_ports_parse_line "$row" || return 1
      if [ "$STATE_BP_RECORD_TYPE" = backend ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
        prior="$STATE_BP_BACKEND_UPSTREAM"; network="$STATE_BP_NETWORK"; break
      fi
    done <"$BACKEND_PORTS_FILE"
    [ -n "$prior" ] || continue
    [ -n "$network" ] || network="${DEFAULT_NETWORK:-dockistrate-net}"
    ip="$(_backend_snapshot_network_ip "$network")" || return 1
    is_valid_ipv4 "$ip" || return 1
    if [ "$unmanaged" != true ]; then domain_config_record_observed_backend "$domain" || return 1; fi
    [ "$ip" != "${prior%:*}" ] || continue
    local _UPDATE_BACKEND_REWRITE_DOMAIN="$domain" _UPDATE_BACKEND_REWRITE_BACKEND_UPSTREAM="$ip:${prior##*:}"
    local _UPDATE_BACKEND_REWRITE_NETWORK="$network" _UPDATE_BACKEND_REWRITE_BACKEND_APPLIED=no
    csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _update_backend_rewrite_backend_row_cb || return 1
    changed=true
  done
  [ "$changed" = true ] || return 0
  if ! (
    local SKIP_DOCKER_CHECKS=true SKIP_UPDATE_NGINX_CONFIG=false DOMAIN_CONFIG_DEFER_RENDER=false
    local TRANSACTION_DEPTH=1 TRANSACTION_OWNER_PID="$$" TRANSACTION_MODE=return
    # A regeneration failure leaves the journal and original archive available
    # for retry, rather than recursively entering this recovery operation.
    function _rollback_handler() { exit 1; }
    function _rollback_handler_return() { exit 1; }
    function create_backup() { :; }
    update_nginx_config || exit 1
    _domain_config_publish_generated || exit 1
  ); then return 1; fi
  if [ -f "$journal/proxy.csv" ]; then
    _domain_runtime_put "$journal/proxy.csv" NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED true || return 1
  fi
}
