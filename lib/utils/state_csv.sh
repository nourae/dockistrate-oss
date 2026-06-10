# shellcheck shell=bash

# Canonical CSV schemas for tool-managed state files.

STATE_BACKEND_PORTS_HEADER="record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location"
STATE_BACKEND_PORTS_COLS=21

STATE_BACKEND_ALIASES_HEADER="record_type,hostname,target_domain"
STATE_BACKEND_ALIASES_COLS=3

STATE_DEDICATED_HOST_INHERITANCE_HEADER="hostname,inherit_mtls,inherit_acl,inherit_security_rules,inherit_headers,inherit_paths"
STATE_DEDICATED_HOST_INHERITANCE_COLS=6

STATE_GLOBAL_SETTINGS_HEADER="setting_key,setting_value"
STATE_GLOBAL_SETTINGS_COLS=2

STATE_CUSTOM_HEADERS_HEADER="header_type,header_name,header_value"
STATE_CUSTOM_HEADERS_COLS=3

STATE_BACKEND_HEADERS_HEADER="domain,header_type,header_name,header_value"
STATE_BACKEND_HEADERS_COLS=4

STATE_BACKEND_HTTP_VERSIONS_HEADER="domain,http_version"
STATE_BACKEND_HTTP_VERSIONS_COLS=2

STATE_PORT_TLS_PROTOCOLS_HEADER="listen_port,tls_protocols"
STATE_PORT_TLS_PROTOCOLS_COLS=2

STATE_PORT_TLS_CIPHERS_HEADER="listen_port,tls_ciphers"
STATE_PORT_TLS_CIPHERS_COLS=2

STATE_NGINX_DIRECTIVES_HEADER="scope,domain,listen_port,path_prefix,directive_mode,directive_name,directive_value"
STATE_NGINX_DIRECTIVES_COLS=7

STATE_BACKEND_MTLS_HEADER="domain,mtls_directory"
STATE_BACKEND_MTLS_COLS=2

STATE_BACKEND_CLIENT_IP_HEADERS_HEADER="domain,client_ip_header_name"
STATE_BACKEND_CLIENT_IP_HEADERS_COLS=2

STATE_BACKEND_PROXY_IP_HEADERS_HEADER="domain,proxy_ip_header_name"
STATE_BACKEND_PROXY_IP_HEADERS_COLS=2

STATE_BACKEND_DOCKER_OPTS_HEADER="key,docker_options"
STATE_BACKEND_DOCKER_OPTS_COLS=2

STATE_BACKEND_ACL_POLICIES_HEADER="domain,acl_policy"
STATE_BACKEND_ACL_POLICIES_COLS=2

STATE_BACKEND_ACL_STATUSES_HEADER="domain,acl_status_code"
STATE_BACKEND_ACL_STATUSES_COLS=2

STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER="domain,security_rule_status_code"
STATE_BACKEND_SECURITY_RULE_STATUSES_COLS=2

STATE_SECURITY_IP_RULES_HEADER="enabled,domain,scope,action,ip_value,status_code"
STATE_SECURITY_IP_RULES_COLS=6

STATE_SECURITY_RULES_HEADER="enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location"
STATE_SECURITY_RULES_COLS=47

STATE_ACCESS_LOG_FIELDS_HEADER="log_field"
STATE_ACCESS_LOG_FIELDS_COLS=1

function state_dedicated_host_inheritance_file() {
  echo "${CONFIG_DIR}/dedicated_host_inheritance.csv"
}

function state_csv_require_file() {
  local file="${1:-}" header="${2:-}"
  csv_require_header "$file" "$header"
}

function state_csv_ensure_all_state_files() {
  local dedicated_inheritance_file
  dedicated_inheritance_file="$(state_dedicated_host_inheritance_file)"

  state_csv_require_file "$GLOBAL_SETTINGS_FILE" "$STATE_GLOBAL_SETTINGS_HEADER" || return 1
  state_csv_require_file "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" || return 1
  state_csv_require_file "$BACKEND_ALIASES_FILE" "$STATE_BACKEND_ALIASES_HEADER" || return 1
  state_csv_require_file "$dedicated_inheritance_file" "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" || return 1
  state_csv_require_file "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER" || return 1
  state_csv_require_file "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" || return 1
  state_csv_require_file "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" || return 1
  state_csv_require_file "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" || return 1
  state_csv_require_file "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" || return 1
  state_csv_require_file "$NGINX_DIRECTIVES_FILE" "$STATE_NGINX_DIRECTIVES_HEADER" || return 1
  state_csv_require_file "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" || return 1
  state_csv_require_file "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" || return 1
  state_csv_require_file "$BACKEND_PROXY_IP_HEADER_FILE" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" || return 1
  state_csv_require_file "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER" || return 1
  state_csv_require_file "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" || return 1
  state_csv_require_file "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" || return 1
  state_csv_require_file "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" || return 1
  state_csv_require_file "$SECURITY_IP_RULES_FILE" "$STATE_SECURITY_IP_RULES_HEADER" || return 1
  state_csv_require_file "$SECURITY_RULES_FILE" "$STATE_SECURITY_RULES_HEADER" || return 1
  if declare -F validate_access_log_fields_state_for_render >/dev/null 2>&1; then
    validate_access_log_fields_state_for_render || return 1
  fi
  state_csv_require_file "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" || return 1
}

function state_csv_get_two_col_value() {
  local file="${1:-}" header="${2:-}" key="${3:-}" default_value="${4:-}"
  local line="" line_no=0
  local value="$default_value"

  [ -f "$file" ] || {
    printf '%s\n' "$value"
    return 0
  }
  state_csv_require_file "$file" "$header" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || {
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne 2 ]; then
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected 2, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    if [ "${CSV_FIELDS[0]}" = "$key" ]; then
      value="${CSV_FIELDS[1]}"
      break
    fi
  done <"$file"

  printf '%s\n' "$value"
}

function state_csv_upsert_two_col_value() {
  local file="${1:-}" header="${2:-}" key="${3:-}" value="${4:-}"
  local line="" line_no=0 replaced=0
  local tmp_file=""

  state_csv_require_file "$file" "$header" || return 1
  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$header" >"$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne 2 ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected 2, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    if [ "${CSV_FIELDS[0]}" = "$key" ]; then
      csv_join_row "$key" "$value" >>"$tmp_file"
      replaced=1
    else
      csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
    fi
  done <"$file"

  if [ "$replaced" -eq 0 ]; then
    csv_join_row "$key" "$value" >>"$tmp_file"
  fi

  finalize_temp_file "$file" "$tmp_file"
}

function state_csv_delete_two_col_key() {
  local file="${1:-}" header="${2:-}" key="${3:-}"
  local line="" line_no=0
  local tmp_file=""

  state_csv_require_file "$file" "$header" || return 1
  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$header" >"$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne 2 ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected 2, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    if [ "${CSV_FIELDS[0]}" != "$key" ]; then
      csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
    fi
  done <"$file"

  finalize_temp_file "$file" "$tmp_file"
}

function state_csv_has_row_by_keys() {
  local file="${1:-}" header="${2:-}" expected_cols="${3:-0}" key_count="${4:-0}"
  local -a keys=()
  local i=0 line="" line_no=0
  local found=1

  if [ "$key_count" -lt 1 ]; then
    return 1
  fi

  shift 4 || true
  for ((i = 0; i < key_count; i++)); do
    keys+=("${1:-}")
    shift || true
  done

  [ -f "$file" ] || return 1
  state_csv_require_file "$file" "$header" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || return 1
    if [ "$expected_cols" -gt 0 ] && [ "$CSV_FIELD_COUNT" -ne "$expected_cols" ]; then
      return 1
    fi

    found=0
    for ((i = 0; i < key_count; i++)); do
      if [ "${CSV_FIELDS[$i]-}" != "${keys[$i]}" ]; then
        found=1
        break
      fi
    done
    [ "$found" -eq 0 ] && return 0
  done <"$file"

  return 1
}

function state_csv_delete_by_keys() {
  local file="${1:-}" header="${2:-}" expected_cols="${3:-0}" key_count="${4:-0}"
  local -a keys=()
  local i=0 line="" line_no=0
  local tmp_file="" is_match=0

  if [ "$key_count" -lt 1 ]; then
    echo "[Error] state_csv_delete_by_keys requires key_count >= 1." >&2
    return 1
  fi

  shift 4 || true
  for ((i = 0; i < key_count; i++)); do
    keys+=("${1:-}")
    shift || true
  done

  state_csv_require_file "$file" "$header" || return 1
  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$header" >"$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$expected_cols" -gt 0 ] && [ "$CSV_FIELD_COUNT" -ne "$expected_cols" ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${expected_cols}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    is_match=1
    for ((i = 0; i < key_count; i++)); do
      if [ "${CSV_FIELDS[$i]-}" != "${keys[$i]}" ]; then
        is_match=0
        break
      fi
    done

    if [ "$is_match" -eq 0 ]; then
      csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
    fi
  done <"$file"

  finalize_temp_file "$file" "$tmp_file"
}

function state_csv_upsert_row_by_keys() {
  local file="${1:-}" header="${2:-}" expected_cols="${3:-0}" key_count="${4:-0}"
  local -a keys=() new_row=()
  local i=0 line="" line_no=0 replaced=0 is_match=0
  local tmp_file=""

  if [ "$key_count" -lt 1 ]; then
    echo "[Error] state_csv_upsert_row_by_keys requires key_count >= 1." >&2
    return 1
  fi

  shift 4 || true
  for ((i = 0; i < key_count; i++)); do
    keys+=("${1:-}")
    shift || true
  done

  if [ "${1:-}" != "--" ]; then
    echo "[Error] state_csv_upsert_row_by_keys requires '--' before row fields." >&2
    return 1
  fi
  shift || true
  new_row=("$@")

  if [ "$expected_cols" -gt 0 ] && [ "${#new_row[@]}" -ne "$expected_cols" ]; then
    echo "[Error] Invalid upsert row width for ${file}: expected ${expected_cols}, got ${#new_row[@]}" >&2
    return 1
  fi

  state_csv_require_file "$file" "$header" || return 1
  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$header" >"$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$expected_cols" -gt 0 ] && [ "$CSV_FIELD_COUNT" -ne "$expected_cols" ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${expected_cols}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    is_match=1
    for ((i = 0; i < key_count; i++)); do
      if [ "${CSV_FIELDS[$i]-}" != "${keys[$i]}" ]; then
        is_match=0
        break
      fi
    done

    if [ "$is_match" -eq 1 ]; then
      csv_join_row "${new_row[@]}" >>"$tmp_file"
      replaced=1
    else
      csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
    fi
  done <"$file"

  if [ "$replaced" -eq 0 ]; then
    csv_join_row "${new_row[@]}" >>"$tmp_file"
  fi

  finalize_temp_file "$file" "$tmp_file"
}

function state_backend_ports_assign_from_fields() {
  if [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_PORTS_COLS" ]; then
    echo "[Error] backend_ports row must have ${STATE_BACKEND_PORTS_COLS} fields, got ${CSV_FIELD_COUNT}" >&2
    return 1
  fi

  STATE_BP_RECORD_TYPE="${CSV_FIELDS[0]}"
  STATE_BP_DOMAIN="${CSV_FIELDS[1]}"
  STATE_BP_BACKEND_UPSTREAM="${CSV_FIELDS[2]}"
  STATE_BP_NETWORK="${CSV_FIELDS[3]}"
  STATE_BP_PATH_PREFIX="${CSV_FIELDS[4]}"
  STATE_BP_HEADER_SET="${CSV_FIELDS[5]}"
  STATE_BP_LISTEN_PORT="${CSV_FIELDS[6]}"
  STATE_BP_UPSTREAM_PORT="${CSV_FIELDS[7]}"
  STATE_BP_PROTOCOL="${CSV_FIELDS[8]}"
  STATE_BP_CERT_REF="${CSV_FIELDS[9]}"
  STATE_BP_WS="${CSV_FIELDS[10]}"
  STATE_BP_REDIRECT_FLAG="${CSV_FIELDS[11]}"
  STATE_BP_REDIRECT_CODE="${CSV_FIELDS[12]}"
  STATE_BP_HTTP3="${CSV_FIELDS[13]}"
  STATE_BP_ALT_SVC="${CSV_FIELDS[14]}"
  STATE_BP_PATH_MATCH="${CSV_FIELDS[15]}"
  STATE_BP_PATH_PRIORITY="${CSV_FIELDS[16]}"
  STATE_BP_PATH_TARGET="${CSV_FIELDS[17]}"
  STATE_BP_PATH_REWRITE="${CSV_FIELDS[18]}"
  STATE_BP_REASON="${CSV_FIELDS[19]}"
  STATE_BP_LOC="${CSV_FIELDS[20]}"
}

function state_backend_ports_parse_line() {
  local line="${1:-}"
  csv_parse_line "$line" || return 1
  state_backend_ports_assign_from_fields
}

function state_backend_ports_row_backend() {
  local domain="${1:-}" backend_upstream="${2:-}" network="${3:-}"
  csv_join_row "backend" "$domain" "$backend_upstream" "$network" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" ""
}

function state_backend_ports_row_port() {
  local domain="${1:-}" listen_port="${2:-}" upstream_port="${3:-}" protocol="${4:-}"
  local cert_ref="${5:-}" ws="${6:-}" redirect_flag="${7:-}" redirect_code="${8:-}" http3="${9:-off}" alt_svc="${10:-auto}"
  csv_join_row "port" "$domain" "" "" "" "" "$listen_port" "$upstream_port" "$protocol" "$cert_ref" "$ws" "$redirect_flag" "$redirect_code" "$http3" "$alt_svc" "" "" "" "" "" ""
}

function state_backend_ports_row_path() {
  local domain="${1:-}" path_prefix="${2:-}" header_set="${3:-}" listen_port="${4:-}"
  local ws="${5:-}" redirect_flag="${6:-}" redirect_code="${7:-}"
  local match_mode="${8:-prefix}" priority="${9:-100}" target="${10:-}" rewrite="${11:-none}" reason="${12:--}" loc="${13:-auto}"
  csv_join_row "path" "$domain" "" "" "$path_prefix" "$header_set" "$listen_port" "" "" "" "$ws" "$redirect_flag" "$redirect_code" "" "" "$match_mode" "$priority" "$target" "$rewrite" "$reason" "$loc"
}

function state_nginx_directives_assign_from_fields() {
  if [ "$CSV_FIELD_COUNT" -ne "$STATE_NGINX_DIRECTIVES_COLS" ]; then
    echo "[Error] nginx_directives row must have ${STATE_NGINX_DIRECTIVES_COLS} fields, got ${CSV_FIELD_COUNT}" >&2
    return 1
  fi

  STATE_ND_SCOPE="${CSV_FIELDS[0]}"
  STATE_ND_DOMAIN="${CSV_FIELDS[1]}"
  STATE_ND_LISTEN_PORT="${CSV_FIELDS[2]}"
  STATE_ND_PATH_PREFIX="${CSV_FIELDS[3]}"
  STATE_ND_MODE="${CSV_FIELDS[4]}"
  STATE_ND_DIRECTIVE="${CSV_FIELDS[5]}"
  STATE_ND_VALUE="${CSV_FIELDS[6]}"
}

function state_nginx_directives_parse_line() {
  local line="${1:-}"
  csv_parse_line "$line" || return 1
  state_nginx_directives_assign_from_fields
}

function state_nginx_directives_row() {
  local scope="${1:-}" domain="${2:-}" listen_port="${3:-}" path_prefix="${4:-}" mode="${5:-}" directive="${6:-}" value="${7:-}"
  csv_join_row "$scope" "$domain" "$listen_port" "$path_prefix" "$mode" "$directive" "$value"
}
