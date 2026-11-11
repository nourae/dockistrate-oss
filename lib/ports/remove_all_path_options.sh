# shellcheck shell=bash

function remove_all_path_options() {
  local domain="${1:-}"
  if [ -n "$domain" ]; then
    resolve_backend_domain domain "$domain" true
  fi

  local path_header_dir="${PATH_HEADER_DIR:-}"
  local prep_lock_started=false
  if ! _config_begin_runtime_prep_lock_if_needed prep_lock_started; then
    return 1
  fi

  if [ ! -f "$BACKEND_PORTS_FILE" ] || ! grep -q '^path,' "$BACKEND_PORTS_FILE"; then
    _config_end_runtime_prep_lock_if_started "$prep_lock_started" || true
    echo "[Info] No path overrides configured."
    return
  fi

  local -a removed_headers=()
  local -a keep_headers=()
  local domain_path_present=false
  local line="" line_no=0
  local type="" d="" header=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    type="${STATE_BP_RECORD_TYPE:-}"
    d="${STATE_BP_DOMAIN:-}"
    header="${STATE_BP_HEADER_SET:-}"
    [ "$type" = "path" ] || continue
    if [ "$d" = "$domain" ]; then
      domain_path_present=true
    fi
    [ -n "$header" ] || continue
    if ! is_valid_header_set_name "$header"; then
      echo "[Error] Invalid persisted path header set at line ${line_no} in ${BACKEND_PORTS_FILE}." >&2
      _config_end_runtime_prep_lock_if_started "$prep_lock_started" || true
      return 1
    fi
    [ -n "$domain" ] || continue
    if [ "$d" = "$domain" ]; then
      local seen="false" h
      if [ "${#removed_headers[@]}" -gt 0 ]; then
        for h in "${removed_headers[@]}"; do
          if [ "$h" = "$header" ]; then
            seen="true"
            break
          fi
        done
      fi
      if [ "$seen" = "false" ]; then
        removed_headers+=("$header")
      fi
    else
      local seen="false" h
      if [ "${#keep_headers[@]}" -gt 0 ]; then
        for h in "${keep_headers[@]}"; do
          if [ "$h" = "$header" ]; then
            seen="true"
            break
          fi
        done
      fi
      if [ "$seen" = "false" ]; then
        keep_headers+=("$header")
      fi
    fi
  done <"$BACKEND_PORTS_FILE"

  if [ -z "$domain" ]; then
    local all_started_txn=false
    if ! _config_begin_transaction_if_needed all_started_txn "remove_all_paths"; then
      _config_end_runtime_prep_lock_if_started "$prep_lock_started" || true
      exit 1
    fi
    if ! sed_in_place "/^path,/d" "$BACKEND_PORTS_FILE" || ! nginx_directives_state_remove_for_paths; then
      transaction_return_failure || true
      return 1
    fi
    if [ -n "$path_header_dir" ] && [ -d "$path_header_dir" ]; then
      local all_include_file=""
      for all_include_file in "${path_header_dir%/}/"*.conf; do
        [ -f "$all_include_file" ] || [ -L "$all_include_file" ] || continue
        if ! safe_rm_f "$all_include_file" "$path_header_dir"; then
          transaction_return_failure || true
          return 1
        fi
      done
    fi
    echo "[Info] Removed all path overrides."
    if ! create_backup "" "RemoveAllPaths" || ! update_nginx_config; then
      transaction_return_failure || true
      return 1
    fi
    _config_end_transaction_if_started "$all_started_txn"
    return
  fi

  if [ "$domain_path_present" != true ]; then
    _config_end_runtime_prep_lock_if_started "$prep_lock_started" || true
    echo "[Info] No path overrides configured for ${domain}."
    return
  fi

  local escaped_domain
  escaped_domain="$(escape_sed_literal "$domain")"
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_all_paths_${domain}"; then
    _config_end_runtime_prep_lock_if_started "$prep_lock_started" || true
    exit 1
  fi
  if ! sed_in_place "/^path,${escaped_domain},/d" "$BACKEND_PORTS_FILE" || ! nginx_directives_state_remove_for_paths "$domain"; then
    transaction_return_failure || true
    return 1
  fi

  if [ -n "$path_header_dir" ] && [ "${#removed_headers[@]}" -gt 0 ]; then
    local hdr keep include_file shared
    for hdr in "${removed_headers[@]}"; do
      shared="false"
      if [ "${#keep_headers[@]}" -gt 0 ]; then
        for keep in "${keep_headers[@]}"; do
          if [ "$keep" = "$hdr" ]; then
            shared="true"
            break
          fi
        done
      fi
      if [ "$shared" != "true" ]; then
        include_file="${path_header_dir%/}/${hdr}.conf"
        if ([ -f "$include_file" ] || [ -L "$include_file" ]) &&
          ! safe_rm_f "$include_file" "$path_header_dir"; then
          transaction_return_failure || true
          return 1
        fi
      fi
    done
  fi

  echo "[Info] Removed path overrides for ${domain}."
  if ! create_backup "" "RemoveAllPaths_${domain}" || ! update_nginx_config; then
    transaction_return_failure || true
    return 1
  fi
  _config_end_transaction_if_started "$started_txn"
}
