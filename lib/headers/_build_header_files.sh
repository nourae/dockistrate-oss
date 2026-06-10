# shellcheck shell=bash

function _append_header_map_entry() {
  local name="$1" domain="$2" value="$3" names_var="$4" entry_prefix="$5" seen_prefix="$6"
  # Sanitize the header name for use in a variable
  local key seen_var entry_var
  key="$(echo "$name" | tr 'A-Z-' 'a-z_')"
  seen_var="${seen_prefix}${key}"
  entry_var="${entry_prefix}${key}"

  local seen="${!seen_var-}"
  case " $seen " in
  *" $domain "*) ;;
  *)
    local current="${!entry_var-}"
    printf -v "$entry_var" '%s    %s "%s";\n' "$current" "$domain" "$value"
    printf -v "$seen_var" '%s%s%s' "$seen" "${seen:+ }" "$domain"
    ;;
  esac

  local names="${!names_var-}"
  case " $names " in
  *" $name "*) ;;
  *) printf -v "$names_var" '%s%s%s' "$names" "${names:+ }" "$name" ;;
  esac
}

function _build_header_files() {
  local global_conf="${NGINX_HTTP_CONF_DIR}/custom_headers.conf"
  local backend_conf="${NGINX_HTTP_CONF_DIR}/backend_headers.conf"
  local backend_map_conf="${NGINX_HTTP_CONF_DIR}/backend_header_maps.conf"
  : >"$global_conf"
  : >"$backend_conf"
  : >"$backend_map_conf"
  if [ -f "$CUSTOM_HEADERS_FILE" ]; then
    if ! csv_require_header "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER"; then
      return 1
    fi
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      if ! csv_parse_line "$line"; then
        _persisted_header_error "$CUSTOM_HEADERS_FILE" "$line_no" "$CSV_PARSE_ERROR"
        return 1
      fi
      if [ "$CSV_FIELD_COUNT" -ne "$STATE_CUSTOM_HEADERS_COLS" ]; then
        _persisted_header_error "$CUSTOM_HEADERS_FILE" "$line_no" "expected ${STATE_CUSTOM_HEADERS_COLS} columns, got ${CSV_FIELD_COUNT}"
        return 1
      fi
      local type name value
      type="${CSV_FIELDS[0]}"
      name="${CSV_FIELDS[1]}"
      value="${CSV_FIELDS[2]}"
      if ! _validate_persisted_header_row "$CUSTOM_HEADERS_FILE" "$line_no" "" "$type" "$name" "$value"; then
        return 1
      fi
      local v
      v=$(_escape_header_value "$value")
      if [ "$type" = "request" ]; then
        printf '    proxy_set_header %s "%s";\n' "$name" "$v" >>"$global_conf"
      else
        printf "    add_header %s \"%s\" always;\n" "$name" "$v" >>"$global_conf"
      fi
    done <"$CUSTOM_HEADERS_FILE"
  fi

  # `add_header` directives can't be wrapped in `if ($host ...)` because the
  # header filter runs outside of conditional blocks. Instead, build a `map`
  # keyed by a server-local backend identity variable and reference the
  # resulting variable with `add_header` so response headers follow the matched
  # backend context rather than the raw request Host header.
  # Bash 3.2 (default on macOS) does not support associative arrays, so the
  # original implementation using `declare -A` would fail with "invalid
  # option". To maintain compatibility, collect map entries using dynamically
  # named variables and track the header names in a plain string.

  local _map_resp_names="" _map_req_names=""
  local explicit_keys=""
  if [ -f "$BACKEND_HEADERS_FILE" ]; then
    if ! csv_require_header "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER"; then
      return 1
    fi
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      if ! csv_parse_line "$line"; then
        _persisted_header_error "$BACKEND_HEADERS_FILE" "$line_no" "$CSV_PARSE_ERROR"
        return 1
      fi
      if [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_HEADERS_COLS" ]; then
        _persisted_header_error "$BACKEND_HEADERS_FILE" "$line_no" "expected ${STATE_BACKEND_HEADERS_COLS} columns, got ${CSV_FIELD_COUNT}"
        return 1
      fi
      local domain type name value
      domain="${CSV_FIELDS[0]}"
      type="${CSV_FIELDS[1]}"
      name="${CSV_FIELDS[2]}"
      value="${CSV_FIELDS[3]}"
      if ! _validate_persisted_header_row "$BACKEND_HEADERS_FILE" "$line_no" "$domain" "$type" "$name" "$value" yes; then
        return 1
      fi
      local key
      key="${domain}|${type}|${name}"
      explicit_keys="${explicit_keys}|${key}|"
      local v
      v=$(_escape_header_value "$value")
      if [ "$type" = "request" ]; then
        _append_header_map_entry "$name" "$domain" "$v" _map_req_names "_req_map_entry_" "_req_map_seen_"
      else
        _append_header_map_entry "$name" "$domain" "$v" _map_resp_names "_map_entry_" "_map_seen_"
      fi
    done <"$BACKEND_HEADERS_FILE"
  fi

  if [ -f "$BACKEND_HEADERS_FILE" ] && command -v list_dedicated_hosts_for_backend >/dev/null 2>&1; then
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      if ! csv_parse_line "$line"; then
        _persisted_header_error "$BACKEND_HEADERS_FILE" "$line_no" "$CSV_PARSE_ERROR"
        return 1
      fi
      if [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_HEADERS_COLS" ]; then
        _persisted_header_error "$BACKEND_HEADERS_FILE" "$line_no" "expected ${STATE_BACKEND_HEADERS_COLS} columns, got ${CSV_FIELD_COUNT}"
        return 1
      fi
      local domain type name value
      domain="${CSV_FIELDS[0]}"
      type="${CSV_FIELDS[1]}"
      name="${CSV_FIELDS[2]}"
      value="${CSV_FIELDS[3]}"
      if ! _validate_persisted_header_row "$BACKEND_HEADERS_FILE" "$line_no" "$domain" "$type" "$name" "$value" yes; then
        return 1
      fi
      local v
      v=$(_escape_header_value "$value")
      local dedicated_hosts
      dedicated_hosts="$(list_dedicated_hosts_for_backend "$domain")"
      if [ -n "$dedicated_hosts" ]; then
        local dh
        for dh in $dedicated_hosts; do
          local should_inherit="yes"
          if command -v should_inherit_headers >/dev/null 2>&1; then
            should_inherit_headers "$dh" && should_inherit="yes" || should_inherit="no"
          fi
          [ "$should_inherit" = "yes" ] || continue
          local dh_key
          dh_key="${dh}|${type}|${name}"
          case "$explicit_keys" in
          *"|$dh_key|"*) continue ;;
          esac
          if [ "$type" = "request" ]; then
            _append_header_map_entry "$name" "$dh" "$v" _map_req_names "_req_map_entry_" "_req_map_seen_"
          else
            _append_header_map_entry "$name" "$dh" "$v" _map_resp_names "_map_entry_" "_map_seen_"
          fi
        done
      fi
    done <"$BACKEND_HEADERS_FILE"
  fi

  for name in $_map_req_names; do
    local key var map_content
    key="$(echo "$name" | tr 'A-Z-' 'a-z_')"
    var="backend_req_${key}"
    local entry_var="_req_map_entry_${key}"
    map_content="${!entry_var}"
    {
      printf 'map $%s $%s {\n' "${BACKEND_HEADER_IDENTITY_VAR:-dockistrate_backend_header_key}" "$var"
      printf '    default "";\n'
      printf '%b' "$map_content"
      printf "}\n"
    } >>"$backend_map_conf"
    printf '    proxy_set_header %s $%s;\n' "$name" "$var" >>"$backend_conf"
  done

  for name in $_map_resp_names; do
    local key var map_content
    key="$(echo "$name" | tr 'A-Z-' 'a-z_')"
    var="backend_header_${key}"
    local entry_var="_map_entry_${key}"
    map_content="${!entry_var}"
    {
      # shellcheck disable=SC2016
      printf 'map $%s $%s {\n' "${BACKEND_HEADER_IDENTITY_VAR:-dockistrate_backend_header_key}" "$var"
      printf '    default "";\n'
      printf '%b' "$map_content"
      printf "}\n"
    } >>"$backend_map_conf"
    printf '    add_header %s $%s always;\n' "$name" "$var" >>"$backend_conf"
  done
}
