# shellcheck shell=bash

# Some unit tests source this file directly without loading lib/utils/state_csv.sh.
# Provide local fallbacks to keep strict-mode reads safe in that context.
: "${STATE_BACKEND_DOCKER_OPTS_HEADER:=key,docker_options}"
: "${STATE_BACKEND_DOCKER_OPTS_COLS:=2}"

function backend_has_httpish_port() {
  local domain="$1"
  domain="$(primary_domain_for "$domain")"
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || return 1
    if [ "$STATE_BP_RECORD_TYPE" = "port" ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
      case "$STATE_BP_PROTOCOL" in
      http | https) ;;
      *) continue ;;
      esac
      [ -n "$STATE_BP_LISTEN_PORT" ] || continue
      return 0
    fi
  done <"$BACKEND_PORTS_FILE"
  return 1
}

function get_backend_docker_opts() {
  local key="${1:-}"
  local opts=""
  if [ -n "$key" ] && [ -f "$BACKEND_DOCKER_OPTS_FILE" ]; then
    opts="$(state_csv_get_two_col_value "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER" "$key" "" 2>/dev/null || true)"
  fi
  echo "$opts"
}

# Save Docker options for a backend (remove entry if opts empty)

function get_backend_image() {
  local domain="${1:-}"
  resolve_backend_domain domain "$domain"
  local cname="backend-$(sanitize_domain_name "$domain")"
  docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || true
}

# Get the configured Docker network for a backend, falling back to default

function get_backend_network() {
  local domain="${1:-}"
  resolve_backend_domain domain "$domain"
  local net="$DEFAULT_NETWORK"
  if [ -n "$domain" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
    local line="" line_no=0 val=""
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || continue
      if [ "$STATE_BP_RECORD_TYPE" = "backend" ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
        val="${STATE_BP_NETWORK}"
        [ -n "$val" ] && net="$val"
        break
      fi
    done <"$BACKEND_PORTS_FILE"
  fi
  echo "$net"
}

# Return the configured container port for a backend

function get_backend_port() {
  local domain="${1:-}"
  resolve_backend_domain domain "$domain"
  local port=""
  if [ -n "$domain" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
    local line="" line_no=0 upstream=""
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || continue
      if [ "$STATE_BP_RECORD_TYPE" = "backend" ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
        upstream="${STATE_BP_BACKEND_UPSTREAM}"
        break
      fi
    done <"$BACKEND_PORTS_FILE"
    [ -n "$upstream" ] && port="${upstream##*:}"
  fi
  echo "${port}"
}

# Return a container IP for a specific Docker network, or empty if not attached.
function get_container_network_ip() {
  local cname="${1:-}" network="${2:-}"
  [ -n "$cname" ] || return 1
  [ -n "$network" ] || return 1

  local escaped_network
  escaped_network="${network//\\/\\\\}"
  escaped_network="${escaped_network//\"/\\\"}"

  docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{if eq \$k \"${escaped_network}\"}}{{\$v.IPAddress}}{{end}}{{end}}" "$cname" 2>/dev/null || true
}

function get_container_network_names() {
  local cname="${1:-}"
  [ -n "$cname" ] || return 1
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s\n" $k}}{{end}}' "$cname" 2>/dev/null || true
}

function container_attached_to_network() {
  local cname="${1:-}" network="${2:-}" ip=""
  [ -n "$cname" ] || return 1
  [ -n "$network" ] || return 1
  ip="$(get_container_network_ip "$cname" "$network")"
  [ -n "$ip" ] && [[ "$ip" != "<no"* ]]
}

# Return stored Docker options for a backend, if any

function resolve_backend_domain() {
  local __out_var="$1" input_domain="$2" verbose="${3:-false}"
  require_valid_var_name "$__out_var" || return 1
  local normalized resolved
  normalized="$(normalize_domain "$input_domain")"
  resolved="$(primary_domain_for "$normalized")"
  if [ "$verbose" = true ] && [ "$resolved" != "$normalized" ]; then
    echo "[Info] Using backend '${resolved}' for alias '${normalized}'."
  fi
  printf -v "$__out_var" '%s' "$resolved"
}

# Return 0 if backend has at least one HTTP/HTTPS port mapping (alias-friendly)

function set_backend_docker_opts() {
  local key="${1:-}" opts="${2:-}"
  local cleaned_opts="$opts"
  cleaned_opts="${cleaned_opts//$'\r'/ }"
  cleaned_opts="${cleaned_opts//$'\n'/ }"
  while [[ "$cleaned_opts" == ' '* ]]; do
    cleaned_opts="${cleaned_opts# }"
  done
  while [[ "$cleaned_opts" == *' ' ]]; do
    cleaned_opts="${cleaned_opts% }"
  done

  local old_umask
  old_umask="$(umask)"
  umask 077
  mkdir -p "$(dirname "$BACKEND_DOCKER_OPTS_FILE")"
  if ! state_csv_require_file "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  if [ -n "$cleaned_opts" ]; then
    state_csv_upsert_two_col_value "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER" "$key" "$cleaned_opts"
  else
    state_csv_delete_two_col_key "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER" "$key"
  fi
  chmod 600 "$BACKEND_DOCKER_OPTS_FILE" 2>/dev/null || true
}

function refresh_backend_ips() {
  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    return 0
  fi
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    return 0
  fi
  local changed="no" tmp=""
  make_temp_for_file tmp "$BACKEND_PORTS_FILE" || return 1
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$tmp"

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    case "${STATE_BP_RECORD_TYPE}" in
    backend)
      local domain="${STATE_BP_DOMAIN}" ip="${STATE_BP_BACKEND_UPSTREAM%%:*}" port="${STATE_BP_BACKEND_UPSTREAM##*:}" network="${STATE_BP_NETWORK:-${DEFAULT_NETWORK:-dockistrate-net}}"
      local cname="backend-$(sanitize_domain_name "$domain")"
      if container_exists "$cname"; then
        local cur_ip
        cur_ip="$(get_container_network_ip "$cname" "$network")"
        if [ -n "$cur_ip" ]; then
          if ! is_valid_ipv4 "$cur_ip"; then
            echo "[Warn] Skipping invalid backend IP reported for $domain on $network: ${cur_ip}. Keeping $ip." >&2
            cur_ip=""
          fi
        fi
        if [ -n "$cur_ip" ] && [ "$cur_ip" != "$ip" ]; then
          echo "[Warn] Backend IP for $domain changed from $ip to $cur_ip. Updating." >&2
          log_msg "Backend IP updated for $domain: $ip -> $cur_ip"
          STATE_BP_BACKEND_UPSTREAM="${cur_ip}:${port}"
          changed="yes"
        fi
      fi
      ;;
    esac
    csv_join_row \
      "$STATE_BP_RECORD_TYPE" \
      "$STATE_BP_DOMAIN" \
      "$STATE_BP_BACKEND_UPSTREAM" \
      "$STATE_BP_NETWORK" \
      "$STATE_BP_PATH_PREFIX" \
      "$STATE_BP_HEADER_SET" \
      "$STATE_BP_LISTEN_PORT" \
      "$STATE_BP_UPSTREAM_PORT" \
      "$STATE_BP_PROTOCOL" \
      "$STATE_BP_CERT_REF" \
      "$STATE_BP_WS" \
      "$STATE_BP_REDIRECT_FLAG" \
      "$STATE_BP_REDIRECT_CODE" \
      "$STATE_BP_HTTP3" \
      "$STATE_BP_ALT_SVC" \
      "$STATE_BP_PATH_MATCH" \
      "$STATE_BP_PATH_PRIORITY" \
      "$STATE_BP_PATH_TARGET" \
      "$STATE_BP_PATH_REWRITE" \
      "$STATE_BP_REASON" \
      "$STATE_BP_LOC" \
      >>"$tmp"
  done <"$BACKEND_PORTS_FILE"

  if [ "$changed" = "yes" ]; then
    finalize_temp_file "$BACKEND_PORTS_FILE" "$tmp"
    create_backup "" "RefreshBackendIPs"
  else
    rm -f "$tmp"
  fi
}

# Ensure stored backend networks match the running containers.
# If a backend container is attached to a different network than recorded,
# update the network column and adjust the stored IP to the address on that
# network. This keeps Nginx connected to all required networks.

function refresh_backend_networks() {
  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    return 0
  fi
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    return 0
  fi
  local changed="no" tmp=""
  make_temp_for_file tmp "$BACKEND_PORTS_FILE" || return 1
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$tmp"

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    case "${STATE_BP_RECORD_TYPE}" in
    backend)
      local domain="${STATE_BP_DOMAIN}" ipport="${STATE_BP_BACKEND_UPSTREAM}" stored_net="${STATE_BP_NETWORK}"
      local cname="backend-$(sanitize_domain_name "$domain")"
      if container_exists "$cname"; then
        local nets first_net chosen_net
        nets="$(get_container_network_names "$cname")"
        first_net="$(printf '%s\n' "$nets" | awk 'NF { print; exit }')"
        if [ -n "$nets" ]; then
          chosen_net="$stored_net"
          if [ -z "$stored_net" ] || ! printf '%s\n' "$nets" | grep -Fx -- "$stored_net" >/dev/null; then
            chosen_net="$first_net"
          fi
          if [ -n "$chosen_net" ] && [ "$chosen_net" != "$stored_net" ]; then
            STATE_BP_NETWORK="$chosen_net"
            # Update IP to the address on chosen_net if available
            local cip
            cip="$(get_container_network_ip "$cname" "$chosen_net")"
            if [ -n "$cip" ]; then
              local port="${ipport##*:}"
              STATE_BP_BACKEND_UPSTREAM="${cip}:${port}"
            fi
            changed="yes"
            echo "[Warn] Backend network for $domain updated to $chosen_net." >&2
            log_msg "Backend network updated for $domain: $stored_net -> $chosen_net"
          fi
        fi
      fi
      ;;
    esac
    csv_join_row \
      "$STATE_BP_RECORD_TYPE" \
      "$STATE_BP_DOMAIN" \
      "$STATE_BP_BACKEND_UPSTREAM" \
      "$STATE_BP_NETWORK" \
      "$STATE_BP_PATH_PREFIX" \
      "$STATE_BP_HEADER_SET" \
      "$STATE_BP_LISTEN_PORT" \
      "$STATE_BP_UPSTREAM_PORT" \
      "$STATE_BP_PROTOCOL" \
      "$STATE_BP_CERT_REF" \
      "$STATE_BP_WS" \
      "$STATE_BP_REDIRECT_FLAG" \
      "$STATE_BP_REDIRECT_CODE" \
      "$STATE_BP_HTTP3" \
      "$STATE_BP_ALT_SVC" \
      "$STATE_BP_PATH_MATCH" \
      "$STATE_BP_PATH_PRIORITY" \
      "$STATE_BP_PATH_TARGET" \
      "$STATE_BP_PATH_REWRITE" \
      "$STATE_BP_REASON" \
      "$STATE_BP_LOC" \
      >>"$tmp"
  done <"$BACKEND_PORTS_FILE"

  if [ "$changed" = "yes" ]; then
    finalize_temp_file "$BACKEND_PORTS_FILE" "$tmp"
    create_backup "" "RefreshBackendNetworks"
  else
    rm -f "$tmp"
  fi
}

# Return the Docker image used by a backend container if available

function summarize_container_image() {
  local cname="$1"
  [ -n "$cname" ] || return 0
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  local config repo digest id display=""
  local info
  info="$(docker inspect -f '{{.Config.Image}}|{{.Image}}' "$cname" 2>/dev/null || true)"
  [ -n "$info" ] || return 0
  config="${info%%|*}"
  id="${info##*|}"
  if [ -n "$id" ]; then
    repo="$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$id" 2>/dev/null || true)"
  fi
  if [ -z "$repo" ] && [ -n "$config" ]; then
    repo="$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$config" 2>/dev/null || true)"
  fi
  if [ -n "$repo" ] && [ "$repo" != "<no value>" ]; then
    display="$repo"
  else
    display="$config"
  fi
  digest="${repo#*@sha256:}"
  if [ "$digest" != "$repo" ]; then
    digest="${digest:0:12}"
    display="${repo%@sha256:*}@sha256:${digest}"
  elif [[ "$id" == sha256:* ]]; then
    digest="${id#sha256:}"
    digest="${digest:0:12}"
    display="${config}@sha256:${digest}"
  fi
  if [ -z "$display" ] && [ -n "$config" ]; then
    display="$config"
  fi
  if [ -z "$display" ] && [ -n "$id" ]; then
    local short_id="${id#sha256:}"
    display="sha256:${short_id:0:12}"
  fi
  printf '%s' "$display"
}
