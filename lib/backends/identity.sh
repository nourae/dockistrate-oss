# shellcheck shell=bash

# This internal dynamic-scope flag is set locally only by explicit recreation.
# An inherited environment value must never relax ordinary refresh behavior.
BACKEND_IDENTITY_MIGRATION=false

# Container names are presentation and collision checks only. The state record
# binds one immutable container ID to the token issued for that launch.
function _backend_identity_file() {
  printf '%s\n' "${CONFIG_DIR}/backend_identity.csv"
}

function _backend_identity_valid_token() {
  local value="${1:-}"
  [ "${#value}" -eq 32 ] || return 1
  case "$value" in *[!0-9a-f]*) return 1 ;; esac
}

# Reads never initialize or repair the sidecar. Explicit recreation and cleanup
# may inspect missing state; ordinary resolution requires one row.
function _backend_identity_read() {
  local domain="${1:-}" allow_missing="${2:-false}" file="" line="" line_no=0 seen=$'\n'
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  BACKEND_IDENTITY_ID=""
  BACKEND_IDENTITY_TOKEN=""
  BACKEND_IDENTITY_FOUND=0
  file="$(_backend_identity_file)" || return 1
  if [ "$allow_missing" = true ] && [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ ! -s "$file" ] || ! csv_require_header "$file" "domain,container_id,ownership_token"; then
    echo "[Error] Backend '$domain' has no valid saved container identity; refusing to adopt a container by name." >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line" || [ "$CSV_FIELD_COUNT" -ne 3 ] ||
      [ "${CSV_FIELDS[0]-}" != "$(normalize_domain "${CSV_FIELDS[0]-}")" ] ||
      ! is_valid_domain "${CSV_FIELDS[0]-}" ||
      ! _backend_runtime_is_full_container_id "${CSV_FIELDS[1]-}" ||
      ! _backend_identity_valid_token "${CSV_FIELDS[2]-}"; then
      echo "[Error] Invalid backend container identity state at line $line_no." >&2
      return 1
    fi
    case "$seen" in *$'\n'"${CSV_FIELDS[0]}"$'\n'*)
      echo "[Error] Duplicate backend container identity at line $line_no." >&2
      return 1
      ;;
    esac
    seen+="${CSV_FIELDS[0]}"$'\n'
    if [ "${CSV_FIELDS[0]}" = "$domain" ]; then
      BACKEND_IDENTITY_FOUND=$((BACKEND_IDENTITY_FOUND + 1))
      BACKEND_IDENTITY_ID="${CSV_FIELDS[1]}"
      BACKEND_IDENTITY_TOKEN="${CSV_FIELDS[2]}"
    fi
  done <"$file"
}

function _backend_identity_load() {
  local domain="${1:-}"
  _backend_identity_read "$domain" || return 1
  if [ "$BACKEND_IDENTITY_FOUND" -ne 1 ]; then
    echo "[Error] Backend '$domain' must have exactly one saved container identity; refusing name-based adoption." >&2
    return 1
  fi
}

function _backend_identity_can_replace_unmanaged() {
  local domain="${1:-}"
  _backend_identity_read "$domain" true || return 1
  if [ "$BACKEND_IDENTITY_FOUND" -ne 0 ]; then
    echo "[Error] Backend '$domain' already has a saved identity; explicit unmanaged replacement cannot override it." >&2
    return 1
  fi
}

function _backend_identity_store() {
  local domain="${1:-}" container_id="${2:-}" token="${3:-}" file=""
  [ "$domain" = "$(normalize_domain "$domain")" ] && is_valid_domain "$domain" || return 1
  _backend_runtime_is_full_container_id "$container_id" && _backend_identity_valid_token "$token" || return 1
  _backend_identity_read "$domain" true || return 1
  file="$(_backend_identity_file)" || return 1
  state_csv_upsert_row_by_keys "$file" "domain,container_id,ownership_token" 3 1 "$domain" -- \
    "$domain" "$container_id" "$token" || return 1
  _tighten_file_permissions "$file" 600
}

function _backend_identity_remove() {
  local domain="${1:-}" file=""
  file="$(_backend_identity_file)" || return 1
  [ -f "$file" ] || return 0
  state_csv_delete_by_keys "$file" "domain,container_id,ownership_token" 3 1 "$domain"
}

# Preserve trailing newlines in valid operator paths and quote every control
# byte for a Go string literal. No input can escape into the inspect template.
function _backend_identity_state_dir() {
  _realpath_portable "$STATE_DIR"
}

function _backend_identity_go_literal() {
  local value="${1-}" code=0 char="" octal="" escaped=""
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  for ((code = 1; code < 32; code++)); do
    printf -v octal '%03o' "$code"
    printf -v char '%b' "\\${octal}"
    printf -v escaped '\\x%02x' "$code"
    # Quoted replacement operands gain literal quotes in Bash 3. The search
    # byte is a control character, and the outer assignment keeps it literal.
    value="${value//$char/$escaped}"
  done
  printf '"%s"' "$value"
}

function _backend_identity_inspect() {
  local domain="${1:-}" container_id="${2:-}" token="${3:-}"
  local state_dir="" template="" snapshot=""
  BACKEND_CONTAINER_ID=""
  BACKEND_CONTAINER_TOKEN=""
  BACKEND_CONTAINER_STATUS=""
  BACKEND_CONTAINER_IMAGE=""
  BACKEND_CONTAINER_IMAGE_ID=""
  BACKEND_CONTAINER_NETWORKS=""
  _backend_runtime_is_full_container_id "$container_id" && _backend_identity_valid_token "$token" || return 1
  state_dir="$(_backend_identity_state_dir && printf '.')" || return 1
  state_dir="${state_dir%.}"
  template='{{if and (eq .Id '"$(_backend_identity_go_literal "$container_id")"') (eq (index .Config.Labels "com.dockistrate.managed") "true") (eq (index .Config.Labels "com.dockistrate.role") "backend") (eq (index .Config.Labels "com.dockistrate.state-dir") '"$(_backend_identity_go_literal "$state_dir")"') (eq (index .Config.Labels "com.dockistrate.backend-domain") '"$(_backend_identity_go_literal "$domain")"') (eq (index .Config.Labels "com.dockistrate.backend-launch") '"$(_backend_identity_go_literal "$token")"')}}verified{{else}}unverified{{end}}{{"\n"}}{{.Id}}{{"\n"}}{{.State.Status}}{{"\n"}}{{.Config.Image}}{{"\n"}}{{.Image}}{{"\n"}}{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s|%s\n" $k $v.IPAddress}}{{end}}'
  # Bash 3 can inherit ERR into command substitutions despite this outer test.
  # Handle inspect failure inside the read-only capture before deciding absence.
  if ! snapshot="$(docker inspect -f "$template" "$container_id" 2>/dev/null || exit "$?")"; then
    if _backend_runtime_container_is_absent "$container_id"; then
      echo "[Error] Saved container for backend '$domain' is absent; refusing to adopt a same-name replacement." >&2
      return 2
    fi
    echo "[Error] Cannot verify the saved container for backend '$domain'." >&2
    return 1
  fi
  _backend_identity_parse_snapshot "$domain" "$container_id" "$token" "$snapshot"
}

# Used only after an operator explicitly supplies an immutable ID to recreate an
# unmanaged backend. The caller checks the canonical name on first authorization;
# rollback keeps the same ID even while its presentation name is staged.
function _backend_identity_inspect_unmanaged() {
  local domain="${1:-}" container_id="${2:-}" expected_name="${3:-}"
  local template="" snapshot="" predicate=""
  _backend_identity_clear_snapshot
  _backend_runtime_is_full_container_id "$container_id" || return 1
  predicate='(eq .Id '"$(_backend_identity_go_literal "$container_id")"')'
  if [ -n "$expected_name" ]; then
    predicate+=' (eq .Name '"$(_backend_identity_go_literal "/$expected_name")"')'
  fi
  template='{{if and '"$predicate"'}}verified{{else}}unverified{{end}}{{"\n"}}{{.Id}}{{"\n"}}{{.State.Status}}{{"\n"}}{{.Config.Image}}{{"\n"}}{{.Image}}{{"\n"}}{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s|%s\n" $k $v.IPAddress}}{{end}}'
  if ! snapshot="$(docker inspect -f "$template" "$container_id" 2>/dev/null || exit "$?")"; then
    echo "[Error] Cannot inspect explicitly selected backend container '$container_id'." >&2
    return 1
  fi
  _backend_identity_parse_snapshot "$domain" "$container_id" "" "$snapshot"
}

function _backend_identity_clear_snapshot() {
  BACKEND_CONTAINER_ID=""
  BACKEND_CONTAINER_TOKEN=""
  BACKEND_CONTAINER_STATUS=""
  BACKEND_CONTAINER_IMAGE=""
  BACKEND_CONTAINER_IMAGE_ID=""
  BACKEND_CONTAINER_NETWORKS=""
}

function _backend_identity_parse_snapshot() {
  local domain="${1:-}" container_id="${2:-}" token="${3:-}" snapshot="${4:-}"
  local proof="" returned_id="" status="" image="" image_id="" networks="" network="" ip="" line=""
  {
    if ! { IFS= read -r proof && IFS= read -r returned_id && IFS= read -r status &&
      IFS= read -r image && IFS= read -r image_id; }; then
      proof=unverified
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      network="${line%%|*}"
      ip="${line#*|}"
      if [ "$network" = "$line" ] || ! is_valid_network_name "$network" ||
        { [ -n "$ip" ] && ! is_valid_ipv4 "$ip"; }; then
        proof=unverified
        break
      fi
      networks+="$network|$ip"$'\n'
    done
  } <<<"$snapshot"
  if [ "$proof" != verified ] || [ "$returned_id" != "$container_id" ]; then
    echo "[Error] Container ownership mismatch for backend '$domain'; refusing runtime data or lifecycle changes." >&2
    return 1
  fi
  case "$status" in created | running | paused | restarting | removing | exited | dead) ;; *) return 1 ;; esac
  # Image text is observed metadata. Launches validate their selected image
  # separately, so an explicit --image can repair an invalid saved reference.
  BACKEND_CONTAINER_ID="$container_id"
  BACKEND_CONTAINER_TOKEN="$token"
  BACKEND_CONTAINER_STATUS="$status"
  BACKEND_CONTAINER_IMAGE="$image"
  BACKEND_CONTAINER_IMAGE_ID="$image_id"
  BACKEND_CONTAINER_NETWORKS="$networks"
}

function _backend_container_snapshot() {
  local domain="${1:-}"
  _backend_identity_clear_snapshot
  _backend_identity_load "$domain" || return 1
  _backend_identity_inspect "$domain" "$BACKEND_IDENTITY_ID" "$BACKEND_IDENTITY_TOKEN"
}

function _backend_snapshot_network_ip() {
  local wanted="${1:-}" line=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${line%%|*}" = "$wanted" ]; then
      printf '%s\n' "${line#*|}"
      return 0
    fi
  done <<<"${BACKEND_CONTAINER_NETWORKS:-}"
}

# Stopped containers can retain network membership without an assigned IP.
function _backend_snapshot_has_network() {
  local wanted="${1:-}" line=""
  [ -n "$wanted" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "${line%%|*}" != "$wanted" ] || return 0
  done <<<"${BACKEND_CONTAINER_NETWORKS:-}"
  return 1
}

function _backend_launch_labels() {
  local domain="${1:-}" token="${2:-}" state_dir=""
  state_dir="$(_backend_identity_state_dir && printf '.')" || return 1
  state_dir="${state_dir%.}"
  docker_run_cmd+=(--label "com.dockistrate.managed=true" --label "com.dockistrate.role=backend" \
    --label "com.dockistrate.state-dir=$state_dir" --label "com.dockistrate.backend-domain=$domain" \
    --label "com.dockistrate.backend-launch=$token")
}

# A missing object or legacy identity can be cleaned from state only when the
# canonical name is provably empty. A name collision never grants ownership.
function _backend_cleanup_snapshot() {
  local domain="${1:-}" snapshot_status=0 cname="" occupants="" name="" occupied=false
  _backend_identity_clear_snapshot
  if ! _backend_identity_read "$domain" true; then
    return 1
  fi
  if [ "$BACKEND_IDENTITY_FOUND" -eq 0 ]; then
    # Legacy state has no ID to adopt. Only an empty canonical name can permit
    # state-only cleanup; malformed or duplicate sidecars already failed above.
    snapshot_status=2
  else
    _backend_identity_inspect "$domain" "$BACKEND_IDENTITY_ID" "$BACKEND_IDENTITY_TOKEN" 2>/dev/null || snapshot_status=$?
  fi
  if [ "$snapshot_status" -eq 0 ]; then
    return 0
  fi
  if [ "$snapshot_status" -eq 2 ]; then
    cname="backend-$(sanitize_domain_name "$domain")"
    if occupants="$(docker ps -a --no-trunc --filter "name=^/${cname}$" --format '{{.Names}}' || exit "$?")"; then
      # Docker's name filter is a regex; a literal domain dot can also match a
      # sibling name. Require the exact name before treating it as a conflict.
      while IFS= read -r name || [ -n "$name" ]; do
        if [ "$name" = "$cname" ]; then
          occupied=true
          break
        fi
      done <<<"$occupants"
      [ "$occupied" = false ] && return 0
    fi
  fi
  echo "[Error] Cannot verify ownership for backend '$domain'; refusing cleanup of its container or saved state." >&2
  return 1
}
