# shellcheck shell=bash

if ! declare -F csv_read_records >/dev/null 2>&1; then
  # shellcheck source=../utils/csv_records.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../utils" && pwd)/csv_records.sh"
fi

if ! declare -F __dockistrate_permissions_common_loaded >/dev/null 2>&1; then
  # shellcheck source=../permissions/common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../permissions" && pwd)/common.sh"
fi

function _global_settings_keys() {
  printf '%s\n' ENABLE_AUTO_BACKUPS BACKUP_RETENTION ENABLE_BACKUP_COMPRESSION \
    HTTP_VERSION CLIENT_IP_HEADER PROXY_IP_HEADER TLS_PROTOCOLS TLS_CIPHERS \
    SECURITY_RULE_STATUS ACL_STATUS ACL_POLICY TRUSTED_PROXY_RANGES REAL_IP_RECURSIVE \
    NGINX_DIRECTIVE_STRICT NGINX_DOCKER_OPTS VISIBILITY_POLICY NGINX_IMAGE CERTBOT_IMAGE \
    NGINX_PULL_MODE CERTBOT_PULL_MODE
}

function _global_settings_capture_record() {
  shift 2
  _global_record_values=("$@")
  _global_record_headers=("${CSV_RECORD_HEADERS[@]}")
  _global_record_present=true
}

function _global_settings_validate_extensions() {
  local field_index=0 canonical_index=0 folded=""
  for ((field_index = STATE_GLOBAL_SETTINGS_COLS; field_index < ${#_global_record_headers[@]}; field_index++)); do
    folded="$(printf '%s' "${_global_record_headers[field_index]}" | LC_ALL=C tr '[:upper:]' '[:lower:]')" || return 1
    for ((canonical_index = 0; canonical_index < STATE_GLOBAL_SETTINGS_COLS; canonical_index++)); do
      [ "$folded" != "${_global_record_headers[canonical_index]}" ] || {
        echo '[Error] Extension field conflicts with a named global setting.' >&2; return 1;
      }
    done
  done
}

# Decode only explicitly scoped legacy recovery/conversion. Unknown extension
# keys remain inert data; a header is never used as a shell variable name.
function _global_settings_capture_legacy() {
  local file="$1" line="" line_no=0 key="" known="" default_key="" index=0 found=false seen=$'\n'
  local -a CSV_FIELDS=() known_keys=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  csv_parse_line "$STATE_GLOBAL_SETTINGS_HEADER" || return 1
  _global_record_headers=("${CSV_FIELDS[@]}")
  while IFS= read -r known; do
    known_keys+=("$known")
    default_key="DEFAULT_$known"
    _global_record_values+=("${!default_key}")
  done < <(_global_settings_keys)
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      [ "${line%$'\r'}" = setting_key,setting_value ] || return 1
      continue
    fi
    csv_parse_line "$line" && [ "$CSV_FIELD_COUNT" -eq 2 ] || return 1
    key="${CSV_FIELDS[0]}"
    case "$key" in '' | *$'\r'* | *$'\n'*) return 1 ;; esac
    case "${CSV_FIELDS[1]}" in *$'\r'* | *$'\n'*) return 1 ;; esac
    case "$seen" in *$'\n'"$key"$'\n'*) echo "[Error] Duplicate persisted setting at line $line_no." >&2; return 1 ;; esac
    seen+="$key"$'\n'
    found=false
    for ((index = 0; index < ${#known_keys[@]}; index++)); do
      if [ "${known_keys[index]}" = "$key" ]; then
        _global_record_values[index]="${CSV_FIELDS[1]}"; found=true; break
      fi
    done
    if [ "$found" = false ]; then
      for known in "${_global_record_headers[@]}"; do
        [ "$known" != "$key" ] || { echo '[Error] Legacy extension conflicts with a named global setting field.' >&2; return 1; }
      done
      _global_record_headers+=("$key")
      _global_record_values+=("${CSV_FIELDS[1]}")
    fi
  done <"$file"
  _global_record_present=true
}

function load_config() {
  # Validate without publishing values or changing file permissions.
  _global_settings_file_metadata "$GLOBAL_SETTINGS_FILE" >/dev/null || return 1
  if [ ! -f "$GLOBAL_SETTINGS_FILE" ] || [ ! -s "$GLOBAL_SETTINGS_FILE" ]; then
    echo "[Error] Global settings file is missing or empty: ${GLOBAL_SETTINGS_FILE}" >&2
    return 1
  fi
  local header="" index=0 key="" _global_record_present=false
  local -a _global_record_headers=() _global_record_values=() known_keys=()
  IFS= read -r header <"$GLOBAL_SETTINGS_FILE" || return 1
  if [ "${header%$'\r'}" = setting_key,setting_value ]; then
    [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" = true ] || {
      echo '[Error] Legacy global settings require explicit state migration.' >&2; return 1;
    }
    _global_settings_capture_legacy "$GLOBAL_SETTINGS_FILE" || return 1
  else
    csv_read_records "$GLOBAL_SETTINGS_FILE" "$STATE_GLOBAL_SETTINGS_HEADER" _global_settings_capture_record singleton true || return 1
  fi
  [ "$_global_record_present" = true ] || { echo '[Error] Global settings require one value record.' >&2; return 1; }
  _global_settings_validate_extensions || return 1
  while IFS= read -r key; do
    validate_persisted_setting "$key" "${_global_record_values[index]}" || return 1
    known_keys+=("$key")
    index=$((index + 1))
  done < <(_global_settings_keys)

  config_reset_defaults
  for ((index = 0; index < ${#known_keys[@]}; index++)); do
    printf -v "${known_keys[index]}" '%s' "${_global_record_values[index]}"
  done
  GLOBAL_SETTINGS_EXTENSION_HEADERS=()
  GLOBAL_SETTINGS_EXTENSION_VALUES=()
  for ((index = ${#known_keys[@]}; index < ${#_global_record_headers[@]}; index++)); do
    GLOBAL_SETTINGS_EXTENSION_HEADERS+=("${_global_record_headers[index]}")
    GLOBAL_SETTINGS_EXTENSION_VALUES+=("${_global_record_values[index]}")
  done
  GLOBAL_SETTINGS_EXTENSION_FILE="$GLOBAL_SETTINGS_FILE"
  LOAD_CONFIG_SAW_NGINX_IMAGE=true
  LOAD_CONFIG_SAW_CERTBOT_IMAGE=true
  LOAD_CONFIG_SAW_NGINX_PULL_MODE=true
  LOAD_CONFIG_SAW_CERTBOT_PULL_MODE=true
  LOAD_CONFIG_SAW_NGINX_DIRECTIVE_STRICT=true
  LOAD_CONFIG_SAW_NGINX_DOCKER_OPTS=true
  LOAD_CONFIG_SAW_VISIBILITY_POLICY=true
}

function _global_settings_convert_legacy() (
  local GLOBAL_SETTINGS_FILE="$1" destination="$2"
  local DOMAIN_CONFIG_LEGACY_RECOVERY=true
  load_config || return 1
  _save_config_write_rows >"$destination"
)
