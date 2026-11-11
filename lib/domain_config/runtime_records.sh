# shellcheck shell=bash

# Internal records have named columns too. Legacy key/value access is confined
# to explicit migration and interrupted-journal recovery, never normal startup.
function _domain_runtime_header() {
  case "${1:-}" in
  */operations/*.csv)
    printf '%s\n' 'mode,domain,ready,old_id,old_token,name,new_token,old_state,unmanaged,old_network,new_network,old_network_existed,new_network_existed,network,state_dir,scope,certificate_id,legacy_source_ref,legacy_source_verified,legacy_source_owner,legacy_source_id,legacy_source_key,legacy_source_identity' ;;
  */transaction.csv)
    printf '%s\n' 'journal_version,state_schema_before,owner_pid,backup,target_count,phase,auto_backup_requested' ;;
  */proxy.csv | */proxy.preparing.csv)
    printf '%s\n' 'container_existed,was_running,image,bindings,projection_state,apply_needed' ;;
  */automatic_backup/state.csv) printf '%s\n' 'pointer,checksum,output' ;;
  */backend.csv) printf '%s\n' 'image,container_port,network,state' ;;
  */observed.csv) printf '%s\n' 'container_id,ownership_token,image,image_id,state,network,address' ;;
  */certificate.csv) printf '%s\n' 'provider,port_suffix,source_ref,declared,specification,source_fullchain,source_privkey' ;;
  */backup_manifest.csv) printf '%s\n' 'format_version,state_schema_version' ;;
  *) _domain_config_error "Unknown internal CSV record: ${1:-}"; return 1 ;;
  esac
}

function _domain_runtime_field() {
  case "${1:-}" in
  NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED) printf '%s\n' container_existed ;;
  NGINX_RUNTIME_ROLLBACK_WAS_RUNNING) printf '%s\n' was_running ;;
  NGINX_RUNTIME_ROLLBACK_IMAGE) printf '%s\n' image ;;
  NGINX_RUNTIME_ROLLBACK_BINDINGS) printf '%s\n' bindings ;;
  NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE) printf '%s\n' projection_state ;;
  NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED) printf '%s\n' apply_needed ;;
  *) printf '%s\n' "${1:-}" ;;
  esac
}

function _domain_runtime_default() {
  case "${1##*/}:${2:-}" in
  certificate.csv:provider) printf '%s' custom ;;
  certificate.csv:port_suffix) printf '%s' 443 ;;
  certificate.csv:declared) printf '%s' yes ;;
  transaction.csv:auto_backup_requested | *:ready | *:legacy_source_verified) printf '%s' no ;;
  *:unmanaged | *:new_network_existed) printf '%s' false ;;
  *:old_network_existed) printf '%s' true ;;
  esac
}

function _domain_runtime_legacy_get() {
  local file="$1" wanted="$2" result="${3:-}" line="" number=0 seen=$'\n' key=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ ! -L "$file" ] || return 1
  if [ ! -e "$file" ]; then printf '%s\n' "$result"; return 0; fi
  [ -f "$file" ] && [ -s "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    if [ "$number" -eq 1 ]; then [ "${line%$'\r'}" = key,value ] || return 1; continue; fi
    csv_parse_line "$line" && [ "$CSV_FIELD_COUNT" -eq 2 ] || return 1
    key="${CSV_FIELDS[0]}"
    [ -n "$key" ] || return 1
    case "$seen" in *$'\n'"$key"$'\n'*) return 1 ;; esac
    seen+="$key"$'\n'
    [ "$key" != "$wanted" ] || result="${CSV_FIELDS[1]}"
  done <"$file"
  printf '%s\n' "$result"
}

function _domain_runtime_get() {
  local file="$1" key="$2" fallback="${3:-}" header="" field=""
  [ ! -L "$file" ] || return 1
  if [ ! -e "$file" ]; then printf '%s\n' "$fallback"; return 0; fi
  IFS= read -r header <"$file" || return 1
  if [ "${header%$'\r'}" = key,value ]; then
    if [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" != true ] && [ "${DOMAIN_CONFIG_MIGRATING:-false}" != true ]; then
      _domain_config_error "Legacy runtime CSV requires explicit migration: $file"; return 1
    fi
    _domain_runtime_legacy_get "$file" "$key" "$fallback"
    return $?
  fi
  header="$(_domain_runtime_header "$file")" || return 1
  field="$(_domain_runtime_field "$key")" || return 1
  csv_record_get "$file" "$header" "$field" "$fallback"
}

function _domain_runtime_initialize() {
  local file="$1" header="$2" temporary="" key=""
  local -a CSV_FIELDS=() values=() fields=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  csv_parse_line "$header" || return 1
  fields=("${CSV_FIELDS[@]}")
  for key in "${fields[@]}"; do values+=("$(_domain_runtime_default "$file" "$key")"); done
  make_temp_for_file temporary "$file" || return 1
  if ! { printf '%s\n' "$header" && csv_join_row "${values[@]}"; } >"$temporary" ||
    ! finalize_temp_file_with_mode "$file" "$temporary" 600; then
    rm -f "$temporary"; return 1
  fi
}

function _domain_runtime_put() {
  local file="$1" key="$2" value="${3:-}" header="" field="" existing=""
  [ ! -L "$file" ] || return 1
  if [ -f "$file" ]; then IFS= read -r existing <"$file" || return 1; fi
  if [ "${existing%$'\r'}" = key,value ]; then
    [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" = true ] || {
      _domain_config_error "Legacy runtime CSV requires conversion before writing: $file"; return 1;
    }
    _domain_runtime_legacy_get "$file" "$key" >/dev/null || return 1
    state_csv_upsert_two_col_value "$file" key,value "$key" "$value"
    return $?
  fi
  header="$(_domain_runtime_header "$file")" || return 1
  field="$(_domain_runtime_field "$key")" || return 1
  case ",$header," in *",$field,"*) ;; *) return 1 ;; esac
  [ -e "$file" ] || _domain_runtime_initialize "$file" "$header" || return 1
  csv_record_put "$file" "$header" "$field" "$value" || return 1
  _tighten_file_permissions "$file" 600
}

# SOURCE is immutable; callers publish the fully converted destination through
# their transaction. Unknown or duplicate legacy keys cannot disappear silently.
function _domain_runtime_convert_legacy() {
  local source="$1" destination="$2" header="" first="" line="" number=0 key="" mapped="" seen=$'\n'
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  header="$(_domain_runtime_header "$source")" || return 1
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  IFS= read -r first <"$source" || return 1
  [ "${first%$'\r'}" = key,value ] || {
    csv_read_records "$source" "$header" _domain_runtime_validate_record singleton || return 1
    copy_file_atomic "$source" "$destination" 600
    return $?
  }
  _domain_runtime_initialize "$destination" "$header" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1)); [ "$number" -gt 1 ] || continue
    csv_parse_line "$line" && [ "$CSV_FIELD_COUNT" -eq 2 ] || return 1
    key="${CSV_FIELDS[0]}"; mapped="$(_domain_runtime_field "$key")" || return 1
    case ",$header," in *",$mapped,"*) ;; *) _domain_config_error "Unknown legacy metadata field $key in $source"; return 1 ;; esac
    case "$seen" in *$'\n'"$mapped"$'\n'*) return 1 ;; esac
    seen+="$mapped"$'\n'
    csv_record_put "$destination" "$header" "$mapped" "${CSV_FIELDS[1]}" || return 1
  done <"$source"
}

function _domain_runtime_validate_record() { :; }
