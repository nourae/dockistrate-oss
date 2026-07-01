# shellcheck shell=bash


function _client_ip_value_var() {
  local header="${1:-}"
  header="$(printf '%s' "$header" | tr '[:upper:]' '[:lower:]')"
  if [ "$header" = "x-forwarded-for" ]; then
    echo "\$proxy_add_x_forwarded_for"
  else
    echo "\$remote_addr"
  fi
}

function _nginx_escape_value() {
  local value="${1:-}"
  if declare -F _escape_nginx_value >/dev/null 2>&1; then
    _escape_nginx_value "$value"
    return 0
  fi

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s\n' "$value"
}

function _backend_header_identity_directives() {
  local default_key="${1:-}" alias_keys="${2:-}"
  local var_name="${BACKEND_HEADER_IDENTITY_VAR:-dockistrate_backend_header_key}"
  local escaped_default_key="" alias_key="" escaped_alias_key=""

  [ -n "$default_key" ] || return 0

  escaped_default_key="$(_nginx_escape_value "$default_key")"
  printf '    set $%s "%s";\n' "$var_name" "$escaped_default_key"

  for alias_key in $alias_keys; do
    [ -n "$alias_key" ] || continue
    escaped_alias_key="$(_nginx_escape_value "$alias_key")"
    printf '    if ($host = %s) { set $%s "%s"; }\n' "$alias_key" "$var_name" "$escaped_alias_key"
  done
}

# Generate real_ip module directives when a client IP header is set.
# The header is trusted for clients connecting through `set-trusted-proxies`
# and the resolved address becomes available via `$remote_addr` for ACL checks.

function nginx_container_exists_any() {
  container_exists "$NGINX_CONTAINER_NAME"
}

function _nginx_container_label_value() {
  local label_key="${1:-}" label_value=""
  [ -n "$label_key" ] || return 1
  label_value="$(docker inspect -f "{{index .Config.Labels \"${label_key}\"}}" "$NGINX_CONTAINER_NAME" 2>/dev/null || true)"
  case "$label_value" in
  "" | "<no value>")
    return 0
    ;;
  esac
  printf '%s\n' "$label_value"
}

function _nginx_expected_state_dir_label() {
  if declare -F _realpath_portable >/dev/null 2>&1; then
    _realpath_portable "$STATE_DIR"
  else
    printf '%s\n' "$STATE_DIR"
  fi
}

function _nginx_expected_mount_signatures() {
  printf '%s|%s|false\n' "$NGINX_CONFIG_DIR" "$NGINX_CONTAINER_CONF_ROOT"
  printf '%s|%s|false\n' "$CERTS_DIR" "/etc/letsencrypt"
  printf '%s|%s|false\n' "$ACME_WEBROOT_DIR" "/var/www/certbot"
}

function _nginx_container_has_expected_mounts() {
  local actual_mounts="" expected_mount=""
  actual_mounts="$(docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%t\n" .Source .Destination .RW}}{{end}}' "$NGINX_CONTAINER_NAME" 2>/dev/null || true)"
  [ -n "$actual_mounts" ] || return 1

  while IFS= read -r expected_mount || [ -n "$expected_mount" ]; do
    [ -n "$expected_mount" ] || continue
    if ! printf '%s\n' "$actual_mounts" | grep -Fxq "$expected_mount"; then
      return 1
    fi
  done < <(_nginx_expected_mount_signatures)

  return 0
}

function _nginx_container_network_names() {
  local cname="${1:-}"
  [ -n "$cname" ] || return 1
  if declare -F get_container_network_names >/dev/null 2>&1; then
    get_container_network_names "$cname"
    return $?
  fi
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s\n" $k}}{{end}}' "$cname" 2>/dev/null || true
}

function _nginx_container_network_ip() {
  local cname="${1:-}" network="${2:-}" escaped_network=""
  [ -n "$cname" ] || return 1
  [ -n "$network" ] || return 1
  if declare -F get_container_network_ip >/dev/null 2>&1; then
    get_container_network_ip "$cname" "$network"
    return $?
  fi

  escaped_network="${network//\\/\\\\}"
  escaped_network="${escaped_network//\"/\\\"}"
  docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{if eq \$k \"${escaped_network}\"}}{{\$v.IPAddress}}{{end}}{{end}}" "$cname" 2>/dev/null || true
}

function _nginx_container_attached_to_network() {
  local cname="${1:-}" network="${2:-}" ip=""
  [ -n "$cname" ] || return 1
  [ -n "$network" ] || return 1
  if declare -F container_attached_to_network >/dev/null 2>&1; then
    container_attached_to_network "$cname" "$network"
    return $?
  fi

  ip="$(_nginx_container_network_ip "$cname" "$network")"
  [ -n "$ip" ] && [[ "$ip" != "<no"* ]]
}

function nginx_container_is_managed() {
  local managed_label="" role_label="" state_dir_label="" expected_state_dir=""
  if ! nginx_container_exists_any; then
    return 1
  fi

  managed_label="$(_nginx_container_label_value "$DOCKISTRATE_MANAGED_LABEL_KEY")"
  role_label="$(_nginx_container_label_value "$DOCKISTRATE_ROLE_LABEL_KEY")"
  state_dir_label="$(_nginx_container_label_value "$DOCKISTRATE_STATE_DIR_LABEL_KEY")"
  expected_state_dir="$(_nginx_expected_state_dir_label)"
  if [ "$managed_label" = "true" ] && [ "$role_label" = "$DOCKISTRATE_ROLE_PROXY" ]; then
    [ "$state_dir_label" = "$expected_state_dir" ]
    return $?
  fi
  if [ -n "$managed_label" ] || [ -n "$role_label" ] || [ -n "$state_dir_label" ]; then
    return 1
  fi

  _nginx_container_has_expected_mounts
}

function nginx_container_conflict_exists() {
  nginx_container_exists_any && ! nginx_container_is_managed
}

function _nginx_conflict_error() {
  local context="${1:-this command}"
  echo "[Error] Found container '$NGINX_CONTAINER_NAME', but it is not Dockistrate-managed by this checkout. Resolve that conflict before running ${context}." >&2
  return 1
}

function ensure_no_nginx_container_conflict() {
  local context="${1:-this command}"
  if nginx_container_conflict_exists; then
    _nginx_conflict_error "$context"
    return 1
  fi
  return 0
}

function require_managed_nginx_container() {
  local context="${1:-this command}"
  if ! nginx_container_exists_any; then
    echo "[Error] Nginx container not found." >&2
    return 1
  fi
  if nginx_container_is_managed; then
    return 0
  fi
  _nginx_conflict_error "$context"
  return 1
}

function warn_if_unmanaged_nginx_container_conflict() {
  if nginx_container_conflict_exists; then
    echo "[Warn] Found container '$NGINX_CONTAINER_NAME', but it is not Dockistrate-managed by this checkout. Dockistrate will not reuse or remove it."
    return 0
  fi
  return 1
}

function _ensure_path_header_include() {
  local set_name="${1:-}"
  [ -n "$set_name" ] || return 0
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$PATH_HEADER_DIR" "path header include directory" || return 1
  fi
  mkdir -p "$PATH_HEADER_DIR"
  local include_file="${PATH_HEADER_DIR}/${set_name}.conf"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$PATH_HEADER_DIR" "$include_file" || return 1
  fi
  if [ ! -f "$include_file" ]; then
    : >"$include_file"
  fi
}


function _real_ip_directives() {
  local header="${1:-}" range=""
  if [ -n "$header" ]; then
    validate_trusted_proxy_ranges "$TRUSTED_PROXY_RANGES" || return 1
    echo "    real_ip_header ${header};"
    for range in $TRUSTED_PROXY_RANGES; do
      echo "    set_real_ip_from ${range};"
    done
    echo "    real_ip_recursive ${REAL_IP_RECURSIVE};"
  fi
}


function _mapped_transport_for_protocol() {
  local protocol="${1:-}"
  case "$protocol" in
  udp) printf '%s\n' "udp" ;;
  *) printf '%s\n' "tcp" ;;
  esac
}

function get_all_mapped_port_bindings() {
  # Return unique space-separated list of "port/proto" bindings.
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local bindings="" line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
      if [[ "${STATE_BP_LISTEN_PORT:-}" =~ ^[0-9]+$ ]]; then
        case "${STATE_BP_PROTOCOL:-}" in
        udp)
          bindings+="${STATE_BP_LISTEN_PORT}/udp"$'\n'
          ;;
        http | tcp)
          bindings+="${STATE_BP_LISTEN_PORT}/tcp"$'\n'
          ;;
        https)
          bindings+="${STATE_BP_LISTEN_PORT}/tcp"$'\n'
          if [ "${STATE_BP_HTTP3:-off}" = "on" ]; then
            bindings+="${STATE_BP_LISTEN_PORT}/udp"$'\n'
          fi
          ;;
        *)
          bindings+="${STATE_BP_LISTEN_PORT}/$(_mapped_transport_for_protocol "${STATE_BP_PROTOCOL:-}")"$'\n'
          ;;
        esac
      fi
    done <"$BACKEND_PORTS_FILE"
    printf '%s' "$bindings" | awk 'NF > 0' | sort -u | tr '\n' ' ' | sed 's/ *$//'
  fi
}

function get_all_mapped_ports() {
  # Return unique space-separated list of explicitly mapped ports.
  local bindings ports=""
  bindings="$(get_all_mapped_port_bindings || true)"
  if [ -n "$bindings" ]; then
    ports="$(printf '%s\n' "$bindings" | tr ' ' '\n' | cut -d'/' -f1 | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  fi
  printf '%s\n' "$ports"
}


function get_sizes() {
  docker ps -a --size --format '{{.Names}}|{{.Size}}'
}

# Tail proxy container logs (access/error combined)


function get_stats() {
  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}'
}

# Capture container storage usage


function reload_nginx_if_running() {
  if nginx_container_conflict_exists; then
    _nginx_conflict_error "reload-nginx"
    return 1
  fi
  if nginx_container_is_managed && container_running "$NGINX_CONTAINER_NAME"; then
    if ! docker exec "$NGINX_CONTAINER_NAME" nginx -s reload 2>/dev/null; then
      echo "[Error] Failed to reload Nginx in container '$NGINX_CONTAINER_NAME'." >&2
      return 1
    fi
  fi
}


function add_nginx_networks() {
  if ! nginx_container_is_managed; then
    return 0
  fi
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    return 0
  fi
  local nets=""
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
    [ -n "${STATE_BP_NETWORK:-}" ] || continue
    nets+="${STATE_BP_NETWORK}"$'\n'
  done <"$BACKEND_PORTS_FILE"
  nets="$(printf '%s' "$nets" | awk 'NF > 0' | sort -u)"
  for net in $nets; do
    [ -z "$net" ] && continue
    if ! is_valid_network_name "$net"; then
      echo "[Error] Invalid backend network '${net}'." >&2
      return 1
    fi
    if ! ensure_network_exists "$net"; then
      return 1
    fi
    if ! _nginx_container_attached_to_network "$NGINX_CONTAINER_NAME" "$net"; then
      docker network connect "$net" "$NGINX_CONTAINER_NAME" 2>/dev/null || true
    fi
    if ! _nginx_container_attached_to_network "$NGINX_CONTAINER_NAME" "$net"; then
      echo "[Error] Failed to connect Nginx container '${NGINX_CONTAINER_NAME}' to network '${net}'." >&2
      return 1
    fi
  done
}

# Disconnect Nginx from Docker networks no longer used by any backend


function normalize_nginx_image() {
  local image="${1:-}" last_segment
  [ -n "$image" ] || return 0

  if [[ "$image" != *"@"* ]]; then
    last_segment="${image##*/}"
    if [[ "$last_segment" != *":"* ]]; then
      echo "${image}:latest"
      return 0
    fi
  fi

  echo "$image"
}
