# shellcheck shell=bash

function _emit_path_locations() {
  local file="$1" domain="$2" listen_port="$3" upstream="$4" default_ws="$5" default_redirect="$6" default_code="$7" pip_line="$8" cip_line="$9" http_version="${10}" fallback_domain="${11:-}"

  domain="$(normalize_domain "$domain")"
  if [ -n "$fallback_domain" ]; then
    fallback_domain="$(normalize_domain "$fallback_domain")"
  fi

  local base_ws="$default_ws"
  [ -n "$base_ws" ] || base_ws="no"
  local redirect_flag="$default_redirect"
  case "$redirect_flag" in
  on | off) ;;
  *) redirect_flag="off" ;;
  esac
  local redirect_code="$default_code"

  local path_entries="" line="" line_no=0 sort_key="" sorted_entry="" path_source_domain="$domain"
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
      return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || return 1
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
      if [ "$STATE_BP_RECORD_TYPE" = "path" ] && [ "$(normalize_domain "$STATE_BP_DOMAIN")" = "$domain" ] && [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ]; then
        local priority_value
        priority_value="${STATE_BP_PATH_PRIORITY:-100}"
        [[ "$priority_value" =~ ^[0-9]+$ ]] || priority_value="100"
        printf -v sort_key '%05d\t%05d' "$priority_value" $((99999 - ${#STATE_BP_PATH_PREFIX}))
        path_entries+="${sort_key}"$'\t'"$line"$'\n'
      fi
    done <"$BACKEND_PORTS_FILE"

    # For dedicated hosts, fall back to target-domain path entries if:
    # 1) no host-specific path entries exist, and
    # 2) path inheritance is enabled.
    if [ -z "$path_entries" ] && [ -n "$fallback_domain" ]; then
      local should_inherit="yes"
      if command -v should_inherit_paths >/dev/null 2>&1; then
        should_inherit_paths "$domain" && should_inherit="yes" || should_inherit="no"
      fi
      if [ "$should_inherit" = "yes" ]; then
        path_source_domain="$fallback_domain"
        line_no=0
        while IFS= read -r line || [ -n "$line" ]; do
          line_no=$((line_no + 1))
          [ "$line_no" -eq 1 ] && continue
          state_backend_ports_parse_line "$line" || return 1
          [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
          if [ "$STATE_BP_RECORD_TYPE" = "path" ] && [ "$(normalize_domain "$STATE_BP_DOMAIN")" = "$path_source_domain" ] && [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ]; then
            local priority_value
            priority_value="${STATE_BP_PATH_PRIORITY:-100}"
            [[ "$priority_value" =~ ^[0-9]+$ ]] || priority_value="100"
            printf -v sort_key '%05d\t%05d' "$priority_value" $((99999 - ${#STATE_BP_PATH_PREFIX}))
            path_entries+="${sort_key}"$'\t'"$line"$'\n'
          fi
        done <"$BACKEND_PORTS_FILE"
      fi
    fi
  fi

  if [ -n "$path_entries" ]; then
    local sorted_path_entries=""
    sorted_path_entries="$(printf '%s' "$path_entries" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n)"
    while IFS= read -r sorted_entry || [ -n "$sorted_entry" ]; do
      [ -n "$sorted_entry" ] || continue
      line="${sorted_entry#*$'\t'}"
      state_backend_ports_parse_line "$line" || return 1
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
      local path_prefix header_set path_ws path_redirect path_code path_match path_target path_rewrite path_reason path_loc
      path_prefix="${STATE_BP_PATH_PREFIX}"
      header_set="${STATE_BP_HEADER_SET}"
      path_ws="${STATE_BP_WS}"
      path_redirect="${STATE_BP_REDIRECT_FLAG}"
      path_code="${STATE_BP_REDIRECT_CODE}"
      path_match="${STATE_BP_PATH_MATCH:-prefix}"
      path_target="${STATE_BP_PATH_TARGET:-}"
      path_rewrite="${STATE_BP_PATH_REWRITE:-none}"
      path_reason="${STATE_BP_REASON:--}"
      path_loc="${STATE_BP_LOC:-auto}"
      [ -n "$path_prefix" ] || continue
      local effective_ws="$base_ws"
      case "$path_ws" in
      yes | no) effective_ws="$path_ws" ;;
      esac

      local effective_redirect="$redirect_flag"
      local effective_code="$redirect_code"
      case "$path_redirect" in
      on)
        effective_redirect="on"
        effective_code="${path_code:-$redirect_code}"
        ;;
      off)
        effective_redirect="off"
        effective_code=""
        ;;
      inherit | "") ;;
      *)
        if [ -n "$path_redirect" ] && [ "$path_redirect" != "inherit" ]; then
          effective_redirect="$path_redirect"
          effective_code="${path_code:-$redirect_code}"
        fi
        ;;
      esac
      if [ "$effective_redirect" = "on" ] && [ -z "$effective_code" ]; then
        effective_code="${redirect_code:-301}"
      fi

      local header_line=""
      if [ -n "$header_set" ]; then
        _ensure_path_header_include "$header_set"
        header_line="        include ${NGINX_CONTAINER_HTTP_CONF_DIR}/path_headers/${header_set}.conf;"
      fi

      local path_directive_fallback=""
      if [ "$path_source_domain" != "$domain" ]; then
        path_directive_fallback="$path_source_domain"
      fi

      if ! _write_location_block "$file" "$path_prefix" "$upstream" "$effective_ws" "$domain" "$pip_line" "$cip_line" "$header_line" "$effective_redirect" "$effective_code" "$http_version" "$path_match" "$path_target" "$path_rewrite" "$path_reason" "$path_loc" "$listen_port" "$path_directive_fallback"; then
        return 1
      fi
    done <<<"$sorted_path_entries"
  fi

  local catchall_directive_fallback=""
  if [ "$path_source_domain" != "$domain" ]; then
    catchall_directive_fallback="$path_source_domain"
  fi

  if ! _write_location_block "$file" "/" "$upstream" "$base_ws" "$domain" "$pip_line" "$cip_line" "" "$redirect_flag" "$redirect_code" "$http_version" "prefix" "" "none" "-" "auto" "$listen_port" "$catchall_directive_fallback"; then
    return 1
  fi
}
