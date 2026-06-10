# shellcheck shell=bash

function remove_all_path_options() {
  local domain="${1:-}"
  if [ ! -f "$BACKEND_PORTS_FILE" ] || ! grep -q '^path,' "$BACKEND_PORTS_FILE"; then
    echo "[Info] No path overrides configured."
    return
  fi

  local path_header_dir="${PATH_HEADER_DIR:-}"
  if [ -z "$domain" ]; then
    local started_txn=false
    if ! _config_begin_transaction_if_needed started_txn "remove_all_paths"; then
      exit 1
    fi
    sed_in_place "/^path,/d" "$BACKEND_PORTS_FILE"
    if [ -n "$path_header_dir" ] && [ -d "$path_header_dir" ]; then
      rm -f "${path_header_dir%/}/"*.conf 2>/dev/null || true
    fi
    echo "[Info] Removed all path overrides."
    create_backup "" "RemoveAllPaths"
    update_nginx_config
    _config_end_transaction_if_started "$started_txn"
    return
  fi

  resolve_backend_domain domain "$domain" true
  local escaped_domain
  escaped_domain="$(escape_sed_literal "$domain")"
  if ! grep -q "^path,${escaped_domain}," "$BACKEND_PORTS_FILE"; then
    echo "[Info] No path overrides configured for ${domain}."
    return
  fi

  local -a removed_headers=()
  local -a keep_headers=()
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
    [ -n "$header" ] || continue
    if [ "$d" = "$domain" ]; then
      local seen="false" h
      for h in "${removed_headers[@]}"; do
        if [ "$h" = "$header" ]; then
          seen="true"
          break
        fi
      done
      if [ "$seen" = "false" ]; then
        removed_headers+=("$header")
      fi
    else
      local seen="false" h
      for h in "${keep_headers[@]}"; do
        if [ "$h" = "$header" ]; then
          seen="true"
          break
        fi
      done
      if [ "$seen" = "false" ]; then
        keep_headers+=("$header")
      fi
    fi
  done <"$BACKEND_PORTS_FILE"

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_all_paths_${domain}"; then
    exit 1
  fi
  sed_in_place "/^path,${escaped_domain},/d" "$BACKEND_PORTS_FILE"

  if [ -n "$path_header_dir" ]; then
    local hdr keep include_file shared
    for hdr in "${removed_headers[@]}"; do
      shared="false"
      for keep in "${keep_headers[@]}"; do
        if [ "$keep" = "$hdr" ]; then
          shared="true"
          break
        fi
      done
      if [ "$shared" != "true" ]; then
        include_file="${path_header_dir%/}/${hdr}.conf"
        [ -f "$include_file" ] && rm -f "$include_file"
      fi
    done
  fi

  echo "[Info] Removed path overrides for ${domain}."
  create_backup "" "RemoveAllPaths_${domain}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
