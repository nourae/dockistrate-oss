# shellcheck shell=bash

# Some unit tests source this file directly without loading lib/utils/state_csv.sh.
# Provide local fallbacks to keep strict-mode reads safe in that context.
: "${STATE_BACKEND_DOCKER_OPTS_HEADER:=domain,docker_options}"
: "${STATE_BACKEND_DOCKER_OPTS_COLS:=2}"

if ! declare -F csv_read_records >/dev/null 2>&1; then
  # shellcheck source=../utils/csv_records.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../utils" && pwd)/csv_records.sh"
fi

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
  local _backend_opts_target="${1:-}" _backend_opts_value=""
  _backend_opts_target="${_backend_opts_target#backend:}"
  [ -n "$_backend_opts_target" ] || return 1
  _backend_docker_options_read "$BACKEND_DOCKER_OPTS_FILE" _backend_docker_options_lookup || return 1
  printf '%s\n' "$_backend_opts_value"
}

function _backend_docker_options_read() {
  local file="$1" _backend_opts_callback="$2" header="" _backend_opts_legacy=false _backend_opts_seen=$'\n'
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r header <"$file" || return 1
  if [ "${header%$'\r'}" = key,docker_options ]; then
    [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" = true ] || {
      echo '[Error] Legacy backend Docker options require explicit state migration.' >&2; return 1;
    }
    _backend_opts_legacy=true
    csv_read_records "$file" key,docker_options _backend_docker_options_checked_row table
  else
    csv_read_records "$file" "$STATE_BACKEND_DOCKER_OPTS_HEADER" _backend_docker_options_checked_row table
  fi
}

function _backend_docker_options_checked_row() {
  local row_domain="$3"
  if [ "$_backend_opts_legacy" = true ]; then
    case "$row_domain" in backend:*) row_domain="${row_domain#backend:}" ;; *) return 1 ;; esac
  fi
  is_valid_domain "$row_domain" && [ "$row_domain" = "$(normalize_domain "$row_domain")" ] || return 1
  case "$_backend_opts_seen" in *$'\n'"$row_domain"$'\n'*) echo '[Error] Duplicate backend Docker options record.' >&2; return 1 ;; esac
  _backend_opts_seen+="$row_domain"$'\n'
  "$_backend_opts_callback" "$1" "$2" "$row_domain" "$4"
}

function _backend_docker_options_lookup() {
  [ "$3" != "$_backend_opts_target" ] || _backend_opts_value="$4"
  return 0
}

function _backend_docker_options_emit() {
  csv_join_row "$3" "$4"
}

function _backend_docker_opts_convert_legacy() (
  local source="$1" destination="$2" DOMAIN_CONFIG_LEGACY_RECOVERY=true
  { printf '%s\n' "$STATE_BACKEND_DOCKER_OPTS_HEADER" &&
    _backend_docker_options_read "$source" _backend_docker_options_emit; } >"$destination"
)

function _backend_docker_options_rewrite() {
  if [ "$3" = "$_backend_opts_target" ]; then
    _backend_opts_found=true
    [ -z "$_backend_opts_value" ] || csv_join_row "$3" "$_backend_opts_value"
  else
    csv_join_row "$3" "$4"
  fi
}

# Save Docker options for a backend (remove entry if opts empty)

function get_backend_image() {
  local domain="${1:-}"
  resolve_backend_domain domain "$domain"
  _backend_container_snapshot "$domain" || return $?
  printf '%s\n' "$BACKEND_CONTAINER_IMAGE"
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
  key="${key#backend:}"
  local cleaned_opts="$opts"
  cleaned_opts="${cleaned_opts//$'\r'/ }"
  cleaned_opts="${cleaned_opts//$'\n'/ }"
  while [[ "$cleaned_opts" == ' '* ]]; do
    cleaned_opts="${cleaned_opts# }"
  done
  while [[ "$cleaned_opts" == *' ' ]]; do
    cleaned_opts="${cleaned_opts% }"
  done

  is_valid_domain "$key" && [ "$key" = "$(normalize_domain "$key")" ] || return 1
  _csv_runtime_state_guard_file_and_dir_if_declared "$BACKEND_DOCKER_OPTS_FILE" 'backend Docker options' || return 1
  local old_umask temporary="" _backend_opts_target="$key" _backend_opts_value="$cleaned_opts" _backend_opts_found=false
  old_umask="$(umask)"
  umask 077
  mkdir -p "$(dirname "$BACKEND_DOCKER_OPTS_FILE")"
  umask "$old_umask"
  make_temp_for_file temporary "$BACKEND_DOCKER_OPTS_FILE" || return 1
  if ! { printf '%s\n' "$STATE_BACKEND_DOCKER_OPTS_HEADER" &&
    _backend_docker_options_read "$BACKEND_DOCKER_OPTS_FILE" _backend_docker_options_rewrite; } >"$temporary"; then
    rm -f "$temporary"; return 1
  fi
  if [ "$_backend_opts_found" = false ] && [ -n "$cleaned_opts" ]; then
    csv_join_row "$key" "$cleaned_opts" >>"$temporary" || { rm -f "$temporary"; return 1; }
  fi
  finalize_temp_file_with_mode "$BACKEND_DOCKER_OPTS_FILE" "$temporary" 600
}

function _refresh_backend_capture_observation() {
  declare -F domain_config_record_observed_snapshot >/dev/null 2>&1 || return 0
  local observation=""
  observation="$(csv_join_row "$1" "$2" "$3" "${BACKEND_CONTAINER_ID:-}" \
    "${BACKEND_CONTAINER_TOKEN:-}" "${BACKEND_CONTAINER_IMAGE:-}" \
    "${BACKEND_CONTAINER_IMAGE_ID:-}" "${BACKEND_CONTAINER_STATUS:-}")" || return 1
  _refresh_observations+=("$observation")
}

# Build the entire replacement before writing: one failed identity leaves every
# row intact. Each backend contributes network and address data from one verified
# snapshot; a same-name container is never queried.
function _refresh_backend_runtime() {
  local mode="${1:-all}"
  [ "${SKIP_DOCKER_CHECKS:-}" != true ] || return 0
  [ -f "$BACKEND_PORTS_FILE" ] || return 0
  local changed=no tmp="" line="" line_no=0 network="" ip="" chosen="" entry=""
  local -a CSV_FIELDS=() _refresh_observations=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" || return 1
  make_temp_for_file tmp "$BACKEND_PORTS_FILE" || return 1
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line" || [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_PORTS_COLS" ]; then
      rm -f "$tmp"
      return 1
    fi
    if [ "${CSV_FIELDS[0]}" = backend ]; then
      if [ "${BACKEND_IDENTITY_MIGRATION:-false}" = true ] &&
        _backend_identity_can_replace_unmanaged "${CSV_FIELDS[1]}" 2>/dev/null; then
        echo "[Warn] Backend '${CSV_FIELDS[1]}' still requires explicit identity migration; preserving its saved route without runtime discovery." >&2
        csv_join_row "${CSV_FIELDS[@]}" >>"$tmp" || { rm -f "$tmp"; return 1; }
        continue
      fi
      if ! _backend_container_snapshot "${CSV_FIELDS[1]}"; then
        rm -f "$tmp"
        return 1
      fi
      if declare -F domain_config_backend_stopped >/dev/null 2>&1 &&
        domain_config_backend_stopped "${CSV_FIELDS[1]}"; then
        # Stopped containers need no address. The renderer uses an explicitly
        # unavailable upstream, never an old address Docker may have recycled.
        _refresh_backend_capture_observation "${CSV_FIELDS[1]}" "${CSV_FIELDS[3]:-${DEFAULT_NETWORK:-dockistrate-net}}" '' || { rm -f "$tmp"; return 1; }
        csv_join_row "${CSV_FIELDS[@]}" >>"$tmp" || { rm -f "$tmp"; return 1; }
        continue
      fi
      network="${CSV_FIELDS[3]:-${DEFAULT_NETWORK:-dockistrate-net}}"
      chosen="$network"
      ip="$(_backend_snapshot_network_ip "$network")"
      if [ -z "$ip" ] && [ "$mode" != ip ]; then
        while IFS= read -r entry || [ -n "$entry" ]; do
          [ -n "${entry#*|}" ] || continue
          chosen="${entry%%|*}"
          ip="${entry#*|}"
          break
        done <<<"$BACKEND_CONTAINER_NETWORKS"
      fi
      if [ -z "$ip" ]; then
        echo "[Error] Verified backend '${CSV_FIELDS[1]}' has no usable IPv4 address on its configured network; refusing stale upstream state." >&2
        rm -f "$tmp"
        return 1
      fi
      if [ "$chosen" != "${CSV_FIELDS[3]}" ] || [ "$ip" != "${CSV_FIELDS[2]%:*}" ]; then
        echo "[Warn] Updating verified backend '${CSV_FIELDS[1]}' to $ip on $chosen." >&2
        CSV_FIELDS[2]="$ip:${CSV_FIELDS[2]##*:}"
        CSV_FIELDS[3]="$chosen"
        changed=yes
      fi
      _refresh_backend_capture_observation "${CSV_FIELDS[1]}" "$chosen" "$ip" || { rm -f "$tmp"; return 1; }
    fi
    if ! csv_join_row "${CSV_FIELDS[@]}" >>"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  done <"$BACKEND_PORTS_FILE"
  # No observations are published until all rows and identities pass. Reuse
  # the captured proof so the sidecar and cache describe the same inspection.
  local observation="" BACKEND_CONTAINER_ID="" BACKEND_CONTAINER_TOKEN=""
  local BACKEND_CONTAINER_IMAGE="" BACKEND_CONTAINER_IMAGE_ID="" BACKEND_CONTAINER_STATUS=""
  if [ "${#_refresh_observations[@]}" -gt 0 ]; then
    for observation in "${_refresh_observations[@]}"; do
      csv_parse_line "$observation" && [ "$CSV_FIELD_COUNT" -eq 8 ] || { rm -f "$tmp"; return 1; }
      BACKEND_CONTAINER_ID="${CSV_FIELDS[3]}"; BACKEND_CONTAINER_TOKEN="${CSV_FIELDS[4]}"
      BACKEND_CONTAINER_IMAGE="${CSV_FIELDS[5]}"; BACKEND_CONTAINER_IMAGE_ID="${CSV_FIELDS[6]}"
      BACKEND_CONTAINER_STATUS="${CSV_FIELDS[7]}"
      domain_config_record_observed_snapshot "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]}" "${CSV_FIELDS[2]}" || { rm -f "$tmp"; return 1; }
    done
  fi
  if [ "$changed" = yes ]; then
    finalize_temp_file "$BACKEND_PORTS_FILE" "$tmp" || return 1
    create_backup "" "RefreshBackendRuntime" || return 1
  else
    rm -f "$tmp"
  fi
}

function refresh_backend_ips() {
  _refresh_backend_runtime ip
}

function refresh_backend_networks() {
  _refresh_backend_runtime all
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
