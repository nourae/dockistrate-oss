# shellcheck shell=bash

function _build_header_files() {
  local global_conf="${NGINX_HTTP_CONF_DIR}/custom_headers.conf"
  local backend_conf="${NGINX_HTTP_CONF_DIR}/backend_headers.conf"
  local backend_map_conf="${NGINX_HTTP_CONF_DIR}/backend_header_maps.conf"
  local global_content="" backend_content="" maps_content=""
  local _header_record_scope=global _header_record_owner=""
  local _header_row_index=-1 _header_row_added=no
  local -a _header_row_keys=() _header_row_owners=() _header_row_types=()
  local -a _header_row_names=() _header_row_values=() _header_row_lines=()
  local -a map_keys=() map_types=() map_names=() map_entries=()
  local i=0 j=0 explicit_count=0 map_index=0 type="" name="" value="" key="" var=""
  local domain="" dedicated_hosts="" dh="" should_inherit="" entry=""

  csv_read_records "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER" _header_collect_record table || return 1
  for ((i = 0; i < ${#_header_row_keys[@]}; i++)); do
    type="${_header_row_types[i]}"; name="${_header_row_names[i]}"
    value="$(_escape_header_value "${_header_row_values[i]}")"
    if [ "$type" = request ]; then
      printf -v global_content '%s    proxy_set_header %s "%s";\n' "$global_content" "$name" "$value"
    else
      printf -v global_content '%s    add_header %s "%s" always;\n' "$global_content" "$name" "$value"
    fi
  done

  _header_row_keys=(); _header_row_owners=(); _header_row_types=()
  _header_row_names=(); _header_row_values=(); _header_row_lines=()
  _header_record_scope=backend
  csv_read_records "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" _header_collect_record table || return 1
  explicit_count="${#_header_row_keys[@]}"
  if command -v list_dedicated_hosts_for_backend >/dev/null 2>&1; then
    for ((i = 0; i < explicit_count; i++)); do
      domain="${_header_row_owners[i]}"; type="${_header_row_types[i]}"
      name="${_header_row_names[i]}"; value="${_header_row_values[i]}"
      dedicated_hosts="$(list_dedicated_hosts_for_backend "$domain")" || return 1
      for dh in $dedicated_hosts; do
        should_inherit="$(get_dedicated_host_inheritance "$dh" headers)" || return 1
        [ "$should_inherit" = yes ] || continue
        # All explicit rows are collected first. An override wins regardless
        # of how either owner capitalized the header name.
        _header_rows_find "$dh" "$type" "$name"
        [ "$_header_row_index" -lt 0 ] || continue
        _header_rows_add "$BACKEND_HEADERS_FILE" "${_header_row_lines[i]}" "$dh" "$type" "$name" "$value" || return 1
      done
    done
  fi

  # Response directives cannot be wrapped in host conditionals. Group one map
  # per type and case-insensitive name, keeping each owner's value as a row.
  # Local indexed arrays work in Bash 3 and cannot leak entries between renders.
  for ((i = 0; i < ${#_header_row_keys[@]}; i++)); do
    type="${_header_row_types[i]}"; name="${_header_row_names[i]}"
    key="${type}|$(_header_name_identity "$name")"
    map_index=-1
    for ((j = 0; j < ${#map_keys[@]}; j++)); do
      if [ "${map_keys[j]}" = "$key" ]; then map_index="$j"; break; fi
    done
    if [ "$map_index" -lt 0 ]; then
      map_index="${#map_keys[@]}"
      map_keys+=("$key"); map_types+=("$type"); map_names+=("$name"); map_entries+=("")
    fi
    value="$(_escape_header_value "${_header_row_values[i]}")"
    printf -v entry '%s    %s "%s";\n' "${map_entries[map_index]}" "${_header_row_owners[i]}" "$value"
    map_entries[map_index]="$entry"
  done

  for type in request response; do
    for ((i = 0; i < ${#map_keys[@]}; i++)); do
      [ "${map_types[i]}" = "$type" ] || continue
      name="${map_names[i]}"
      key="$(_header_name_identity "$name")"; key="${key//-/_}"
      if [ "$type" = request ]; then
        var="backend_req_${key}"
        printf -v backend_content '%s    proxy_set_header %s $%s;\n' "$backend_content" "$name" "$var"
      else
        var="backend_header_${key}"
        printf -v backend_content '%s    add_header %s $%s always;\n' "$backend_content" "$name" "$var"
      fi
      printf -v maps_content '%smap $%s $%s {\n    default "";\n%s}\n' "$maps_content" \
        "${BACKEND_HEADER_IDENTITY_VAR:-dockistrate_backend_header_key}" "$var" "${map_entries[i]}"
    done
  done

  # Validate the entire input before changing generated files. Entries already
  # contain real newlines and escaped Nginx values; interpreting backslashes
  # again can reopen a quoted value, so always emit accumulated content as %s.
  printf '%s' "$global_content" >"$global_conf" || return 1
  printf '%s' "$backend_content" >"$backend_conf" || return 1
  printf '%s' "$maps_content" >"$backend_map_conf"
}
