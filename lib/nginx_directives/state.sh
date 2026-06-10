# shellcheck shell=bash

_ND_REMOVE_SCOPE_FILTER=""
_ND_REMOVE_DOMAIN_FILTER=""
_ND_REMOVE_PORT_FILTER=""
_ND_REMOVE_PATH_FILTER=""
_ND_REMOVE_DIRECTIVE_FILTER=""
_ND_REMOVED_COUNT=0

function _nginx_directive_resolve_effective_backend_domain() {
  local domain="${1:-}" normalized="" target=""
  normalized="$(normalize_domain "$domain")"

  if backend_exists "$normalized"; then
    printf '%s\n' "$normalized"
    return 0
  fi

  target="$(backend_for_dedicated_host "$normalized" || true)"
  if [ -n "$target" ] && backend_exists "$target"; then
    printf '%s\n' "$target"
    return 0
  fi

  return 1
}

function _nginx_directive_lookup_target_mapping_protocol() {
  local domain="${1:-}" listen_port="${2:-}" backend_domain="" line="" line_no=0

  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" >/dev/null 2>&1; then
    return 1
  fi
  if ! backend_domain="$(_nginx_directive_resolve_effective_backend_domain "$domain" 2>/dev/null)"; then
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    if ! state_backend_ports_parse_line "$line"; then
      continue
    fi
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
    [ "$STATE_BP_DOMAIN" = "$backend_domain" ] || continue
    [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ] || continue

    printf '%s\n' "$STATE_BP_PROTOCOL"
    return 0
  done <"$BACKEND_PORTS_FILE"

  return 1
}

function _nginx_directive_validate_scope_target_protocol() {
  local scope="${1:-}" domain="${2:-}" listen_port="${3:-}" protocol=""

  if [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" ]; then
    local normalized_domain=""
    normalized_domain="$(normalize_domain "$domain")"
    if ! backend_exists "$normalized_domain"; then
      echo "[Error] Stream directive scopes require a backend domain. '${domain}' is not a configured backend." >&2
      return 1
    fi
  fi

  if ! protocol="$(_nginx_directive_lookup_target_mapping_protocol "$domain" "$listen_port" 2>/dev/null)"; then
    echo "[Error] Port mapping '${domain}:${listen_port}' was not found." >&2
    return 1
  fi

  case "$scope" in
  "$NGINX_DIRECTIVE_SCOPE_PORT" | "$NGINX_DIRECTIVE_SCOPE_PATH")
    if [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
      echo "[Error] Port mapping '${domain}:${listen_port}' uses protocol '${protocol}'. Use scope 'stream-port' for stream directives." >&2
      return 1
    fi
    ;;
  "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT")
    if [ "$protocol" != "tcp" ] && [ "$protocol" != "udp" ]; then
      echo "[Error] Port mapping '${domain}:${listen_port}' uses protocol '${protocol}'. Scope 'stream-port' requires a TCP or UDP mapping." >&2
      return 1
    fi
    ;;
  esac

  return 0
}

function _nginx_directive_path_exists_for_target() {
  local domain="${1:-}" listen_port="${2:-}" path_prefix="${3:-}" line="" line_no=0
  local target_domain=""
  if ! target_domain="$(_nginx_directive_resolve_effective_backend_domain "$domain" 2>/dev/null)"; then
    return 1
  fi
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" >/dev/null 2>&1; then
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "$STATE_BP_RECORD_TYPE" = "path" ] || continue
    [ "$STATE_BP_DOMAIN" = "$target_domain" ] || continue
    [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ] || continue
    [ "$STATE_BP_PATH_PREFIX" = "$path_prefix" ] || continue
    return 0
  done <"$BACKEND_PORTS_FILE"

  return 1
}

function _nginx_directive_path_target_write_allowed() {
  local domain="${1:-}" normalized_domain=""
  normalized_domain="$(normalize_domain "$domain")"

  if dedicated_host_exists "$normalized_domain"; then
    if ! should_inherit_paths "$normalized_domain"; then
      echo "[Error] Dedicated host '${normalized_domain}' has inherit_paths=no. Enable path inheritance or target the backend domain." >&2
      return 1
    fi
  fi

  return 0
}

function nginx_directives_ensure_state_file() {
  state_csv_require_file "$NGINX_DIRECTIVES_FILE" "$STATE_NGINX_DIRECTIVES_HEADER"
}

function nginx_directives_resolve_scope_target() {
  local out_scope="${1:-}" out_domain="${2:-}" out_listen_port="${3:-}" out_path_prefix="${4:-}"
  local scope_input="${5:-}" scope="" domain="${6:-}" listen_port="${7:-}" path_prefix="${8:-}" validation_mode="${9:-write}"

  require_valid_var_name "$out_scope" || return 1
  require_valid_var_name "$out_domain" || return 1
  require_valid_var_name "$out_listen_port" || return 1
  require_valid_var_name "$out_path_prefix" || return 1

  case "$validation_mode" in
  write | cleanup)
    ;;
  *)
    echo "[Error] Invalid validation mode '${validation_mode}'. Use one of: write, cleanup." >&2
    return 1
    ;;
  esac

  if ! scope="$(nginx_directive_normalize_scope "$scope_input" 2>/dev/null)"; then
    echo "[Error] Invalid scope '${scope_input}'. Use one of: global, backend, port, path, stream-global, stream-backend, stream-port." >&2
    return 1
  fi

  case "$scope" in
  "$NGINX_DIRECTIVE_SCOPE_GLOBAL" | "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL")
    domain=""
    listen_port=""
    path_prefix=""
    ;;
  "$NGINX_DIRECTIVE_SCOPE_BACKEND" | "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND")
    if ! domain="$(nginx_directive_normalize_target_domain "$domain" 2>/dev/null)"; then
      if [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" ]; then
        echo "[Error] Invalid stream backend domain '${domain}'." >&2
      else
        echo "[Error] Invalid backend domain '${domain}'." >&2
      fi
      return 1
    fi
    listen_port=""
    path_prefix=""
    ;;
  "$NGINX_DIRECTIVE_SCOPE_PORT" | "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT")
    if ! domain="$(nginx_directive_normalize_target_domain "$domain" 2>/dev/null)"; then
      if [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" ]; then
        echo "[Error] Invalid stream port domain '${domain}'." >&2
      else
        echo "[Error] Invalid port domain '${domain}'." >&2
      fi
      return 1
    fi
    if ! is_valid_port "$listen_port"; then
      echo "[Error] Invalid listen port '${listen_port}'." >&2
      return 1
    fi
    path_prefix=""
    ;;
  "$NGINX_DIRECTIVE_SCOPE_PATH")
    if ! domain="$(nginx_directive_normalize_target_domain "$domain" 2>/dev/null)"; then
      echo "[Error] Invalid path domain '${domain}'." >&2
      return 1
    fi
    if ! is_valid_port "$listen_port"; then
      echo "[Error] Invalid listen port '${listen_port}'." >&2
      return 1
    fi
    if ! is_valid_path_prefix "$path_prefix"; then
      echo "[Error] Invalid path prefix '${path_prefix}'." >&2
      return 1
    fi
    ;;
  esac

  if nginx_directive_scope_requires_domain "$scope" && ! nginx_directive_target_domain_exists "$scope" "$domain"; then
    if nginx_directive_scope_is_stream "$scope"; then
      echo "[Error] Stream directive scopes require a backend domain. '${domain}' is not a configured backend." >&2
    else
      echo "[Error] Domain '${domain}' was not found as a backend or dedicated host." >&2
    fi
    return 1
  fi

  if nginx_directive_scope_requires_port "$scope"; then
    if ! _nginx_directive_validate_scope_target_protocol "$scope" "$domain" "$listen_port"; then
      return 1
    fi
  fi

  if nginx_directive_scope_requires_path "$scope"; then
    if [ "$validation_mode" = "write" ]; then
      if ! _nginx_directive_path_target_write_allowed "$domain"; then
        return 1
      fi
    fi
    if [ "$validation_mode" != "cleanup" ]; then
      if ! _nginx_directive_path_exists_for_target "$domain" "$listen_port" "$path_prefix"; then
        echo "[Error] Path mapping '${domain}:${listen_port}${path_prefix}' was not found." >&2
        return 1
      fi
    fi
  fi

  printf -v "$out_scope" '%s' "$scope"
  printf -v "$out_domain" '%s' "$domain"
  printf -v "$out_listen_port" '%s' "$listen_port"
  printf -v "$out_path_prefix" '%s' "$path_prefix"
}

function nginx_directives_state_upsert() {
  local scope="${1:-}" domain="${2:-}" listen_port="${3:-}" path_prefix="${4:-}" mode="${5:-}" directive="${6:-}" value="${7:-}"
  local line="" line_no=0 replaced=0 tmp_file=""
  local directives_dir=""

  if ! mode="$(nginx_directive_normalize_mode "$mode" 2>/dev/null)"; then
    echo "[Error] Invalid directive mode '${mode}'." >&2
    return 1
  fi

  directives_dir="$(dirname "$NGINX_DIRECTIVES_FILE")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$directives_dir" "nginx directives state directory" || return 1
    runtime_state_path_guard_if_declared "$NGINX_DIRECTIVES_FILE" "nginx directives state file" || return 1
  fi
  mkdir -p "$directives_dir"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$directives_dir" "nginx directives state directory" || return 1
    runtime_state_path_guard_if_declared "$NGINX_DIRECTIVES_FILE" "nginx directives state file" || return 1
  fi
  nginx_directives_ensure_state_file || return 1

  make_temp_for_file tmp_file "$NGINX_DIRECTIVES_FILE" || return 1
  printf '%s\n' "$STATE_NGINX_DIRECTIVES_HEADER" >"$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${NGINX_DIRECTIVES_FILE} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_NGINX_DIRECTIVES_COLS" ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${NGINX_DIRECTIVES_FILE} at line ${line_no}: expected ${STATE_NGINX_DIRECTIVES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    if [ "${CSV_FIELDS[0]}" = "$scope" ] &&
      [ "${CSV_FIELDS[1]}" = "$domain" ] &&
      [ "${CSV_FIELDS[2]}" = "$listen_port" ] &&
      [ "${CSV_FIELDS[3]}" = "$path_prefix" ] &&
      [ "${CSV_FIELDS[5]}" = "$directive" ]; then
      if [ "$replaced" -eq 0 ]; then
        state_nginx_directives_row "$scope" "$domain" "$listen_port" "$path_prefix" "$mode" "$directive" "$value" >>"$tmp_file"
        replaced=1
      fi
      continue
    fi

    state_nginx_directives_row "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]}" "${CSV_FIELDS[2]}" "${CSV_FIELDS[3]}" "${CSV_FIELDS[4]}" "${CSV_FIELDS[5]}" "${CSV_FIELDS[6]}" >>"$tmp_file"
  done <"$NGINX_DIRECTIVES_FILE"

  if [ "$replaced" -eq 0 ]; then
    state_nginx_directives_row "$scope" "$domain" "$listen_port" "$path_prefix" "$mode" "$directive" "$value" >>"$tmp_file"
  fi

  finalize_temp_file "$NGINX_DIRECTIVES_FILE" "$tmp_file"
}

function nginx_directives_state_delete_exact() {
  local scope="${1:-}" domain="${2:-}" listen_port="${3:-}" path_prefix="${4:-}" directive="${5:-}"
  local line="" line_no=0 tmp_file=""

  nginx_directives_ensure_state_file || return 1
  make_temp_for_file tmp_file "$NGINX_DIRECTIVES_FILE" || return 1
  printf '%s\n' "$STATE_NGINX_DIRECTIVES_HEADER" >"$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${NGINX_DIRECTIVES_FILE} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_NGINX_DIRECTIVES_COLS" ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${NGINX_DIRECTIVES_FILE} at line ${line_no}: expected ${STATE_NGINX_DIRECTIVES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    if [ "${CSV_FIELDS[0]}" = "$scope" ] &&
      [ "${CSV_FIELDS[1]}" = "$domain" ] &&
      [ "${CSV_FIELDS[2]}" = "$listen_port" ] &&
      [ "${CSV_FIELDS[3]}" = "$path_prefix" ] &&
      [ "${CSV_FIELDS[5]}" = "$directive" ]; then
      continue
    fi

    state_nginx_directives_row "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]}" "${CSV_FIELDS[2]}" "${CSV_FIELDS[3]}" "${CSV_FIELDS[4]}" "${CSV_FIELDS[5]}" "${CSV_FIELDS[6]}" >>"$tmp_file"
  done <"$NGINX_DIRECTIVES_FILE"

  finalize_temp_file "$NGINX_DIRECTIVES_FILE" "$tmp_file"
}

function _nginx_directives_remove_matching_cb() {
  local scope="${CSV_FIELDS[0]-}"
  local domain="${CSV_FIELDS[1]-}"
  local listen_port="${CSV_FIELDS[2]-}"
  local path_prefix="${CSV_FIELDS[3]-}"
  local directive="${CSV_FIELDS[5]-}"

  if [ -n "${_ND_REMOVE_SCOPE_FILTER:-}" ] && [ "$scope" != "${_ND_REMOVE_SCOPE_FILTER}" ]; then
    return 0
  fi
  if [ -n "${_ND_REMOVE_DOMAIN_FILTER:-}" ]; then
    local normalized_domain
    normalized_domain="$(normalize_domain "$domain")"
    if [ "$normalized_domain" != "${_ND_REMOVE_DOMAIN_FILTER}" ]; then
      return 0
    fi
  fi
  if [ -n "${_ND_REMOVE_PORT_FILTER:-}" ] && [ "$listen_port" != "${_ND_REMOVE_PORT_FILTER}" ]; then
    return 0
  fi
  if [ -n "${_ND_REMOVE_PATH_FILTER:-}" ] && [ "$path_prefix" != "${_ND_REMOVE_PATH_FILTER}" ]; then
    return 0
  fi
  if [ -n "${_ND_REMOVE_DIRECTIVE_FILTER:-}" ] && [ "$directive" != "${_ND_REMOVE_DIRECTIVE_FILTER}" ]; then
    return 0
  fi

  _ND_REMOVED_COUNT=$((_ND_REMOVED_COUNT + 1))
  return 10
}

function nginx_directives_state_remove_matching() {
  local scope_filter="${1:-}" domain_filter="${2:-}" port_filter="${3:-}" path_filter="${4:-}" directive_filter="${5:-}"
  local directives_dir=""

  directives_dir="$(dirname "$NGINX_DIRECTIVES_FILE")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$directives_dir" "nginx directives state directory" || return 1
    runtime_state_path_guard_if_declared "$NGINX_DIRECTIVES_FILE" "nginx directives state file" || return 1
  fi
  mkdir -p "$directives_dir"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$directives_dir" "nginx directives state directory" || return 1
    runtime_state_path_guard_if_declared "$NGINX_DIRECTIVES_FILE" "nginx directives state file" || return 1
  fi
  nginx_directives_ensure_state_file || return 1

  if [ -n "$domain_filter" ]; then
    domain_filter="$(normalize_domain "$domain_filter")"
  fi

  _ND_REMOVE_SCOPE_FILTER="$scope_filter"
  _ND_REMOVE_DOMAIN_FILTER="$domain_filter"
  _ND_REMOVE_PORT_FILTER="$port_filter"
  _ND_REMOVE_PATH_FILTER="$path_filter"
  _ND_REMOVE_DIRECTIVE_FILTER="$directive_filter"
  _ND_REMOVED_COUNT=0

  csv_rewrite_rows \
    "$NGINX_DIRECTIVES_FILE" "$STATE_NGINX_DIRECTIVES_HEADER" "$STATE_NGINX_DIRECTIVES_COLS" \
    _nginx_directives_remove_matching_cb || return 1

  printf '%s\n' "${_ND_REMOVED_COUNT}"
}

function nginx_directives_state_remove_for_domain() {
  local domain="${1:-}"
  [ -n "$domain" ] || return 0
  nginx_directives_state_remove_matching "" "$domain" "" "" "" >/dev/null
}

function nginx_directives_state_remove_for_backend() {
  local domain="${1:-}"
  [ -n "$domain" ] || return 0
  nginx_directives_state_remove_matching "$NGINX_DIRECTIVE_SCOPE_BACKEND" "$domain" "" "" "" >/dev/null
}

function nginx_directives_state_remove_for_port() {
  local domain="${1:-}" listen_port="${2:-}"
  [ -n "$domain" ] || return 0
  [ -n "$listen_port" ] || return 0
  nginx_directives_state_remove_matching "$NGINX_DIRECTIVE_SCOPE_PORT" "$domain" "$listen_port" "" "" >/dev/null
  nginx_directives_state_remove_matching "$NGINX_DIRECTIVE_SCOPE_PATH" "$domain" "$listen_port" "" "" >/dev/null
  nginx_directives_state_remove_matching "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" "$domain" "$listen_port" "" "" >/dev/null
}

function nginx_directives_state_retarget_port_scope_rows() {
  local scope_from="${1:-}" domain="${2:-}" port_from="${3:-}" scope_to="${4:-}" port_to="${5:-}"
  local normalized_scope_from="" normalized_scope_to="" normalized_domain=""
  local line="" line_no=0
  local -a source_modes=()
  local -a source_paths=()
  local -a source_directives=()
  local -a source_values=()
  local i=0

  if ! normalized_scope_from="$(nginx_directive_normalize_scope "$scope_from" 2>/dev/null)"; then
    echo "[Error] Invalid source scope '${scope_from}' for nginx directive retarget." >&2
    return 1
  fi
  if ! normalized_scope_to="$(nginx_directive_normalize_scope "$scope_to" 2>/dev/null)"; then
    echo "[Error] Invalid target scope '${scope_to}' for nginx directive retarget." >&2
    return 1
  fi
  if ! nginx_directive_scope_requires_port "$normalized_scope_from"; then
    echo "[Error] Source scope '${normalized_scope_from}' is not a port-scoped nginx directive target." >&2
    return 1
  fi
  if ! nginx_directive_scope_requires_port "$normalized_scope_to"; then
    echo "[Error] Target scope '${normalized_scope_to}' is not a port-scoped nginx directive target." >&2
    return 1
  fi
  if ! normalized_domain="$(nginx_directive_normalize_target_domain "$domain" 2>/dev/null)"; then
    echo "[Error] Invalid domain '${domain}' for nginx directive retarget." >&2
    return 1
  fi
  if ! is_valid_port "$port_from"; then
    echo "[Error] Invalid source listen port '${port_from}' for nginx directive retarget." >&2
    return 1
  fi
  if ! is_valid_port "$port_to"; then
    echo "[Error] Invalid target listen port '${port_to}' for nginx directive retarget." >&2
    return 1
  fi

  if [ "$normalized_scope_from" = "$normalized_scope_to" ] && [ "$port_from" = "$port_to" ]; then
    return 0
  fi

  nginx_directives_ensure_state_file || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || {
      echo "[Error] Invalid CSV row in ${NGINX_DIRECTIVES_FILE} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_NGINX_DIRECTIVES_COLS" ]; then
      echo "[Error] Invalid CSV column count in ${NGINX_DIRECTIVES_FILE} at line ${line_no}: expected ${STATE_NGINX_DIRECTIVES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    if [ "${CSV_FIELDS[0]}" = "$normalized_scope_from" ] &&
      [ "${CSV_FIELDS[1]}" = "$normalized_domain" ] &&
      [ "${CSV_FIELDS[2]}" = "$port_from" ]; then
      source_paths+=("${CSV_FIELDS[3]}")
      source_modes+=("${CSV_FIELDS[4]}")
      source_directives+=("${CSV_FIELDS[5]}")
      source_values+=("${CSV_FIELDS[6]}")
    fi
  done <"$NGINX_DIRECTIVES_FILE"

  if [ "${#source_directives[@]}" -eq 0 ]; then
    return 0
  fi

  if ! nginx_directives_state_remove_matching "$normalized_scope_from" "$normalized_domain" "$port_from" "" "" >/dev/null; then
    return 1
  fi

  for ((i = 0; i < ${#source_directives[@]}; i++)); do
    if ! nginx_directives_state_upsert \
      "$normalized_scope_to" "$normalized_domain" "$port_to" "${source_paths[$i]}" \
      "${source_modes[$i]}" "${source_directives[$i]}" "${source_values[$i]}"; then
      return 1
    fi
  done

  return 0
}

function nginx_directives_state_get_exact_value() {
  local scope="${1:-}" domain="${2:-}" listen_port="${3:-}" path_prefix="" directive="" default_value=""
  if [ "$#" -ge 6 ]; then
    path_prefix="${4:-}"
    directive="${5:-}"
    default_value="${6:-}"
  else
    path_prefix=""
    directive="${4:-}"
    default_value="${5:-}"
  fi
  local line="" line_no=0

  [ -f "$NGINX_DIRECTIVES_FILE" ] || {
    printf '%s\n' "$default_value"
    return 0
  }
  nginx_directives_ensure_state_file || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_NGINX_DIRECTIVES_COLS" ] || continue

    if [ "${CSV_FIELDS[0]}" = "$scope" ] &&
      [ "${CSV_FIELDS[1]}" = "$domain" ] &&
      [ "${CSV_FIELDS[2]}" = "$listen_port" ] &&
      [ "${CSV_FIELDS[3]}" = "$path_prefix" ] &&
      [ "${CSV_FIELDS[5]}" = "$directive" ]; then
      printf '%s\n' "${CSV_FIELDS[6]}"
      return 0
    fi
  done <"$NGINX_DIRECTIVES_FILE"

  printf '%s\n' "$default_value"
}
