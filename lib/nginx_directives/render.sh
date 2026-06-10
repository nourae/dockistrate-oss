# shellcheck shell=bash

_ND_EFFECTIVE_NAMES=()
_ND_EFFECTIVE_VALUES=()

function _nginx_directive_render_state_error() {
  local line_no="${1:-0}" reason="${2:-invalid nginx directive row}"
  echo "[Error] Invalid nginx_directives.csv row at line ${line_no}: ${reason}" >&2
  return 1
}

function nginx_directives_validate_for_render() {
  local line="" line_no=0

  [ -f "$NGINX_DIRECTIVES_FILE" ] || return 0
  nginx_directives_ensure_state_file || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    if ! csv_parse_line "$line"; then
      _nginx_directive_render_state_error "$line_no" "CSV parse failed (${CSV_PARSE_ERROR})"
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_NGINX_DIRECTIVES_COLS" ]; then
      _nginx_directive_render_state_error "$line_no" "expected ${STATE_NGINX_DIRECTIVES_COLS} columns, got ${CSV_FIELD_COUNT}"
      return 1
    fi

    local scope domain listen_port path_prefix mode directive value normalized_scope normalized_mode
    scope="${CSV_FIELDS[0]}"
    domain="${CSV_FIELDS[1]}"
    listen_port="${CSV_FIELDS[2]}"
    path_prefix="${CSV_FIELDS[3]}"
    mode="${CSV_FIELDS[4]}"
    directive="${CSV_FIELDS[5]}"
    value="${CSV_FIELDS[6]}"

    normalized_scope="$(nginx_directive_normalize_scope "$scope" 2>/dev/null || true)"
    if [ -z "$normalized_scope" ]; then
      _nginx_directive_render_state_error "$line_no" "unknown scope '${scope}'"
      return 1
    fi

    normalized_mode="$(nginx_directive_normalize_mode "$mode" 2>/dev/null || true)"
    if [ -z "$normalized_mode" ]; then
      _nginx_directive_render_state_error "$line_no" "unknown mode '${mode}'"
      return 1
    fi

    case "$normalized_scope" in
    global | stream-global)
      if [ -n "$domain" ] || [ -n "$listen_port" ] || [ -n "$path_prefix" ]; then
        _nginx_directive_render_state_error "$line_no" "${normalized_scope} scope must not set domain, listen_port, or path_prefix"
        return 1
      fi
      ;;
    backend | stream-backend)
      if [ -z "$domain" ] || ! is_valid_domain "$domain"; then
        _nginx_directive_render_state_error "$line_no" "${normalized_scope} scope requires a valid domain"
        return 1
      fi
      if [ "$normalized_scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" ] && ! backend_exists "$domain"; then
        _nginx_directive_render_state_error "$line_no" "stream-backend scope requires a configured backend domain"
        return 1
      fi
      if [ -n "$listen_port" ] || [ -n "$path_prefix" ]; then
        _nginx_directive_render_state_error "$line_no" "${normalized_scope} scope must not set listen_port or path_prefix"
        return 1
      fi
      ;;
    port | stream-port)
      if [ -z "$domain" ] || ! is_valid_domain "$domain"; then
        _nginx_directive_render_state_error "$line_no" "${normalized_scope} scope requires a valid domain"
        return 1
      fi
      if ! is_valid_port "$listen_port"; then
        _nginx_directive_render_state_error "$line_no" "${normalized_scope} scope requires a valid listen_port"
        return 1
      fi
      if [ -n "$path_prefix" ]; then
        _nginx_directive_render_state_error "$line_no" "${normalized_scope} scope must not set path_prefix"
        return 1
      fi
      if declare -F _nginx_directive_validate_scope_target_protocol >/dev/null 2>&1; then
        if ! _nginx_directive_validate_scope_target_protocol "$normalized_scope" "$domain" "$listen_port" >/dev/null 2>&1; then
          _nginx_directive_render_state_error "$line_no" "scope '${normalized_scope}' is incompatible with mapping '${domain}:${listen_port}'"
          return 1
        fi
      fi
      ;;
    path)
      if [ -z "$domain" ] || ! is_valid_domain "$domain"; then
        _nginx_directive_render_state_error "$line_no" "path scope requires a valid domain"
        return 1
      fi
      if ! is_valid_port "$listen_port"; then
        _nginx_directive_render_state_error "$line_no" "path scope requires a valid listen_port"
        return 1
      fi
      if ! is_valid_path_prefix "$path_prefix"; then
        _nginx_directive_render_state_error "$line_no" "path scope requires a valid path_prefix"
        return 1
      fi
      if declare -F _nginx_directive_validate_scope_target_protocol >/dev/null 2>&1; then
        if ! _nginx_directive_validate_scope_target_protocol "$normalized_scope" "$domain" "$listen_port" >/dev/null 2>&1; then
          _nginx_directive_render_state_error "$line_no" "scope '${normalized_scope}' is incompatible with mapping '${domain}:${listen_port}'"
          return 1
        fi
      fi
      if declare -F _nginx_directive_path_exists_for_target >/dev/null 2>&1; then
        if ! _nginx_directive_path_exists_for_target "$domain" "$listen_port" "$path_prefix" >/dev/null 2>&1; then
          _nginx_directive_render_state_error "$line_no" "path scope target '${domain}:${listen_port}${path_prefix}' was not found"
          return 1
        fi
      fi
      ;;
    esac

    if ! nginx_directive_validate_name_token "$directive"; then
      _nginx_directive_render_state_error "$line_no" "invalid directive token '${directive}'"
      return 1
    fi
    if ! nginx_directive_validate_raw_value "$value"; then
      _nginx_directive_render_state_error "$line_no" "unsafe value for '${directive}'"
      return 1
    fi

    if [ "$normalized_mode" = "$NGINX_DIRECTIVE_MODE_MANAGED" ]; then
      if ! nginx_directive_catalog_validate_for_scope "$normalized_scope" "$directive" "$value"; then
        _nginx_directive_render_state_error "$line_no" "managed value failed catalog validation for '${directive}' in scope '${normalized_scope}'"
        return 1
      fi
    fi
  done <"$NGINX_DIRECTIVES_FILE"

  if ! nginx_directives_validate_strict_owned_rows; then
    return 1
  fi

  return 0
}

function nginx_directives_render_global_include() {
  local include_file="$NGINX_DIRECTIVES_GLOBAL_INCLUDE_FILE"
  local include_dir=""
  local line="" line_no=0

  include_dir="$(dirname "$include_file")"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$include_dir" "$include_file" || return 1
  fi
  mkdir -p "$include_dir"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$include_dir" "$include_file" || return 1
  fi
  {
    echo "# Auto-generated nginx global directives"
    if [ -f "$NGINX_DIRECTIVES_FILE" ]; then
      nginx_directives_ensure_state_file || return 1
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        csv_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_NGINX_DIRECTIVES_COLS" ] || continue
        [ "${CSV_FIELDS[0]}" = "$NGINX_DIRECTIVE_SCOPE_GLOBAL" ] || continue
        printf '    %s %s;\n' "${CSV_FIELDS[5]}" "${CSV_FIELDS[6]}"
      done <"$NGINX_DIRECTIVES_FILE"
    fi
  } >"$include_file"
}

function nginx_directives_render_stream_global_include() {
  local include_file="$NGINX_DIRECTIVES_STREAM_GLOBAL_INCLUDE_FILE"
  local include_dir=""
  local line="" line_no=0

  include_dir="$(dirname "$include_file")"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$include_dir" "$include_file" || return 1
  fi
  mkdir -p "$include_dir"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$include_dir" "$include_file" || return 1
  fi
  {
    echo "# Auto-generated nginx stream global directives"
    if [ -f "$NGINX_DIRECTIVES_FILE" ]; then
      nginx_directives_ensure_state_file || return 1
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        csv_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_NGINX_DIRECTIVES_COLS" ] || continue
        [ "${CSV_FIELDS[0]}" = "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL" ] || continue
        printf '    %s %s;\n' "${CSV_FIELDS[5]}" "${CSV_FIELDS[6]}"
      done <"$NGINX_DIRECTIVES_FILE"
    fi
  } >"$include_file"
}

function _nginx_directives_effective_set() {
  local directive="${1:-}" value="${2:-}"
  local i
  for ((i = 0; i < ${#_ND_EFFECTIVE_NAMES[@]}; i++)); do
    if [ "${_ND_EFFECTIVE_NAMES[$i]}" = "$directive" ]; then
      _ND_EFFECTIVE_VALUES[$i]="$value"
      return 0
    fi
  done
  _ND_EFFECTIVE_NAMES+=("$directive")
  _ND_EFFECTIVE_VALUES+=("$value")
}

function _nginx_directives_apply_scope_rows() {
  local scope="${1:-}" domain="${2:-}" listen_port="${3:-}" path_prefix="${4:-}"
  local line="" line_no=0

  [ -f "$NGINX_DIRECTIVES_FILE" ] || return 0
  nginx_directives_ensure_state_file || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_NGINX_DIRECTIVES_COLS" ] || continue

    if [ "${CSV_FIELDS[0]}" != "$scope" ]; then
      continue
    fi

    case "$scope" in
    global | stream-global)
      ;;
    backend | stream-backend)
      [ "${CSV_FIELDS[1]}" = "$domain" ] || continue
      ;;
    port | stream-port)
      [ "${CSV_FIELDS[1]}" = "$domain" ] || continue
      [ "${CSV_FIELDS[2]}" = "$listen_port" ] || continue
      ;;
    path)
      [ "${CSV_FIELDS[1]}" = "$domain" ] || continue
      [ "${CSV_FIELDS[2]}" = "$listen_port" ] || continue
      [ "${CSV_FIELDS[3]}" = "$path_prefix" ] || continue
      ;;
    esac

    _nginx_directives_effective_set "${CSV_FIELDS[5]}" "${CSV_FIELDS[6]}"
  done <"$NGINX_DIRECTIVES_FILE"

  return 0
}

function nginx_directives_collect_effective_for_server() {
  local domain="${1:-}" listen_port="${2:-}" fallback_domain="${3:-}"

  domain="$(normalize_domain "$domain")"
  fallback_domain="$(normalize_domain "$fallback_domain")"

  _ND_EFFECTIVE_NAMES=()
  _ND_EFFECTIVE_VALUES=()

  if [ -n "$fallback_domain" ] && [ "$fallback_domain" != "$domain" ]; then
    _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_BACKEND" "$fallback_domain" ""
    _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_PORT" "$fallback_domain" "$listen_port"
  fi
  _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_BACKEND" "$domain" ""
  _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_PORT" "$domain" "$listen_port"
}

function nginx_directives_collect_effective_for_path() {
  local domain="${1:-}" listen_port="${2:-}" path_prefix="${3:-}" fallback_domain="${4:-}"

  domain="$(normalize_domain "$domain")"
  fallback_domain="$(normalize_domain "$fallback_domain")"

  _ND_EFFECTIVE_NAMES=()
  _ND_EFFECTIVE_VALUES=()

  if [ -n "$fallback_domain" ] && [ "$fallback_domain" != "$domain" ]; then
    _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_PATH" "$fallback_domain" "$listen_port" "$path_prefix"
  fi
  _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_PATH" "$domain" "$listen_port" "$path_prefix"
}

function nginx_directives_collect_effective_for_stream_server() {
  local domain="${1:-}" listen_port="${2:-}"

  domain="$(normalize_domain "$domain")"

  _ND_EFFECTIVE_NAMES=()
  _ND_EFFECTIVE_VALUES=()

  _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" "$domain" ""
  _nginx_directives_apply_scope_rows "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" "$domain" "$listen_port"
}

function nginx_directives_render_server_directives() {
  local config_file="${1:-}" domain="${2:-}" listen_port="${3:-}" fallback_domain="${4:-}"
  local i

  [ -n "$config_file" ] || return 1
  [ -n "$domain" ] || return 1
  [ -n "$listen_port" ] || return 1

  nginx_directives_collect_effective_for_server "$domain" "$listen_port" "$fallback_domain" || return 1

  if [ "${#_ND_EFFECTIVE_NAMES[@]}" -eq 0 ]; then
    return 0
  fi

  echo "    # nginx directive overrides" >>"$config_file"
  for ((i = 0; i < ${#_ND_EFFECTIVE_NAMES[@]}; i++)); do
    printf '    %s %s;\n' "${_ND_EFFECTIVE_NAMES[$i]}" "${_ND_EFFECTIVE_VALUES[$i]}" >>"$config_file"
  done

  return 0
}

function nginx_directives_render_path_directives() {
  local config_file="${1:-}" domain="${2:-}" listen_port="${3:-}" path_prefix="${4:-}" fallback_domain="${5:-}"
  local i

  [ -n "$config_file" ] || return 1
  [ -n "$domain" ] || return 1
  [ -n "$listen_port" ] || return 1
  [ -n "$path_prefix" ] || return 1

  nginx_directives_collect_effective_for_path "$domain" "$listen_port" "$path_prefix" "$fallback_domain" || return 1

  if [ "${#_ND_EFFECTIVE_NAMES[@]}" -eq 0 ]; then
    return 0
  fi

  echo "        # nginx path directive overrides" >>"$config_file"
  for ((i = 0; i < ${#_ND_EFFECTIVE_NAMES[@]}; i++)); do
    printf '        %s %s;\n' "${_ND_EFFECTIVE_NAMES[$i]}" "${_ND_EFFECTIVE_VALUES[$i]}" >>"$config_file"
  done

  return 0
}

function nginx_directives_render_stream_server_directives() {
  local config_file="${1:-}" domain="${2:-}" listen_port="${3:-}"
  local i

  [ -n "$config_file" ] || return 1
  [ -n "$domain" ] || return 1
  [ -n "$listen_port" ] || return 1

  nginx_directives_collect_effective_for_stream_server "$domain" "$listen_port" || return 1

  if [ "${#_ND_EFFECTIVE_NAMES[@]}" -eq 0 ]; then
    return 0
  fi

  echo "    # nginx stream directive overrides" >>"$config_file"
  for ((i = 0; i < ${#_ND_EFFECTIVE_NAMES[@]}; i++)); do
    printf '    %s %s;\n' "${_ND_EFFECTIVE_NAMES[$i]}" "${_ND_EFFECTIVE_VALUES[$i]}" >>"$config_file"
  done

  return 0
}
