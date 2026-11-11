# shellcheck shell=bash

function _escape_header_value() {
  local val="${1:-}"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '%s' "$val"
}

function _is_valid_header_type() {
  case "${1:-}" in
  request | response) return 0 ;;
  *) return 1 ;;
  esac
}

function _persisted_header_error() {
  local file="${1:-}" line_no="${2:-0}" reason="${3:-invalid header row}"
  echo "[Error] Invalid persisted header row in ${file} at line ${line_no}: ${reason}" >&2
  return 1
}

function _validate_persisted_header_row() {
  local file="${1:-}" line_no="${2:-0}" domain="${3:-}" type="${4:-}" name="${5:-}" value="${6:-}" require_domain="${7:-no}"

  if [ "$require_domain" = "yes" ] && [ -z "$domain" ]; then
    _persisted_header_error "$file" "$line_no" "domain cannot be empty"
    return 1
  fi
  if [ -n "$domain" ] && ! is_valid_domain "$domain"; then
    _persisted_header_error "$file" "$line_no" "domain '${domain}' is invalid"
    return 1
  fi
  if ! _is_valid_header_type "$type"; then
    _persisted_header_error "$file" "$line_no" "type '${type}' must be request or response"
    return 1
  fi
  if ! is_valid_header_name "$name"; then
    _persisted_header_error "$file" "$line_no" "header name '${name}' is invalid"
    return 1
  fi
  if ! is_valid_header_value "$value"; then
    _persisted_header_error "$file" "$line_no" "header value for '${name}' is invalid"
    return 1
  fi
  return 0
}

# Header spelling is retained for display and generated directives; identity is
# ASCII case-insensitive. Header names contain only letters, digits and hyphens.
function _header_name_identity() {
  printf '%s' "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# Callers own these indexed arrays as locals so nested validations and repeated
# renders cannot share state: _header_row_keys, _header_row_owners,
# _header_row_types, _header_row_names, _header_row_values, _header_row_lines.
# They also declare local _header_row_index=-1 and _header_row_added=no.
function _header_rows_find() {
  local owner="$1" type="$2" name="$3" key="" i=0
  key="${owner}|${type}|$(_header_name_identity "$name")"
  _header_row_index=-1
  for ((i = 0; i < ${#_header_row_keys[@]}; i++)); do
    if [ "${_header_row_keys[i]}" = "$key" ]; then
      _header_row_index="$i"
      return 0
    fi
  done
}

# Identical variants share one generated row without rewriting their source.
# Compare raw values, before escaping, including an explicitly empty value.
function _header_rows_add() {
  local file="$1" line="$2" owner="$3" type="$4" name="$5" value="$6" repair=""
  _header_row_added=no
  _validate_persisted_header_row "$file" "$line" "$owner" "$type" "$name" "$value" || return 1
  _header_rows_find "$owner" "$type" "$name"
  if [ "$_header_row_index" -ge 0 ]; then
    if [ "${_header_row_values[_header_row_index]}" != "$value" ]; then
      if [ -n "$owner" ]; then
        repair="update-backend-header ${owner} ${type} ${name} VALUE or remove-backend-header ${owner} ${type} ${name}"
      else
        repair="update-header ${type} ${name} VALUE or remove-header ${type} ${name}"
      fi
      _persisted_header_error "$file" "$line" "conflicting values for ${type} header '${name}' in ${owner:-global headers} (first spelling '${_header_row_names[_header_row_index]}' at line ${_header_row_lines[_header_row_index]}); repair with ${repair}"
      return 1
    fi
    return 0
  fi
  _header_row_index="${#_header_row_keys[@]}"
  _header_row_keys+=("${owner}|${type}|$(_header_name_identity "$name")")
  _header_row_owners+=("$owner")
  _header_row_types+=("$type")
  _header_row_names+=("$name")
  _header_row_values+=("$value")
  _header_row_lines+=("$line")
  _header_row_added=yes
}

function _header_collect_record() {
  local file="$1" line="$2" owner="${_header_record_owner:-}"
  shift 2
  if [ "$_header_record_scope" = backend ]; then owner="$1"; shift; fi
  if [ "$_header_record_scope" != global ] && [ -z "$owner" ]; then
    _persisted_header_error "$file" "$line" 'domain cannot be empty'
    return 1
  fi
  _header_rows_add "$file" "$line" "$owner" "$1" "$2" "$3"
}

# Return a canonical, validated view with a header. SCOPE is global, backend,
# or domain; domain additionally takes its owner. Reordered columns are accepted
# by the CSV reader and source bytes are never changed by this read operation.
function _header_records() {
  local file="$1" _header_record_scope="$2" _header_record_owner="${3:-}" schema="" i=0
  local _header_row_index=-1 _header_row_added=no
  local -a _header_row_keys=() _header_row_owners=() _header_row_types=()
  local -a _header_row_names=() _header_row_values=() _header_row_lines=()
  case "$_header_record_scope" in
  global | domain) schema='header_type,header_name,header_value' ;;
  backend) schema='domain,header_type,header_name,header_value' ;;
  *) return 1 ;;
  esac
  csv_read_records "$file" "$schema" _header_collect_record table || return 1
  printf '%s\n' "$schema"
  for ((i = 0; i < ${#_header_row_keys[@]}; i++)); do
    if [ "$_header_record_scope" = backend ]; then
      csv_join_row "${_header_row_owners[i]}" "${_header_row_types[i]}" "${_header_row_names[i]}" "${_header_row_values[i]}"
    else
      csv_join_row "${_header_row_types[i]}" "${_header_row_names[i]}" "${_header_row_values[i]}"
    fi
  done
}

function _header_record_value() {
  local file="$1" _header_record_scope="$2" owner="$3" type="$4" name="$5" schema=""
  local _header_record_owner="" _header_row_index=-1 _header_row_added=no
  local -a _header_row_keys=() _header_row_owners=() _header_row_types=()
  local -a _header_row_names=() _header_row_values=() _header_row_lines=()
  case "$_header_record_scope" in
  global) schema='header_type,header_name,header_value' ;;
  backend) schema='domain,header_type,header_name,header_value' ;;
  *) return 1 ;;
  esac
  csv_read_records "$file" "$schema" _header_collect_record table || return 1
  _header_rows_find "$owner" "$type" "$name"
  if [ "$_header_row_index" -ge 0 ]; then
    printf '%s\n' "${_header_row_values[_header_row_index]}"
  else
    printf '\n'
  fi
}

function _resolve_backend_ip_header() {
  local domain="${1:-}" default_header="${2:-}" file="${3:-}" csv_header="${4:-}" setting="${5:-}"
  local resolved_header="$default_header" custom="" has_explicit_override="no"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  _require_persisted_settings_validation || return 1
  if [ -n "$domain" ]; then
    custom="$(get_validated_backend_setting_override "$file" "$csv_header" "$setting" "$domain")" || return 1
    if [ -n "$custom" ]; then
      resolved_header="$custom"
      [ "$resolved_header" = "off" ] && resolved_header=""
      has_explicit_override="yes"
    fi
  fi
  if [ "$has_explicit_override" = "no" ]; then
    local target_domain should_inherit="yes"
    target_domain="$(backend_for_dedicated_host "$domain")"
    if [ -n "$target_domain" ]; then
      should_inherit="$(get_dedicated_host_inheritance "$domain" headers)" || return 1
      if [ "$should_inherit" = "yes" ]; then
        resolved_header="$(_resolve_backend_ip_header "$target_domain" "$default_header" "$file" "$csv_header" "$setting")" || return 1
      fi
    fi
  fi
  validate_persisted_setting "$setting" "$resolved_header" || return 1
  printf '%s\n' "$resolved_header"
}

function get_backend_client_ip_header() {
  local domain="${1:-}"
  _resolve_backend_ip_header "$domain" "$CLIENT_IP_HEADER" "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" CLIENT_IP_HEADER
}

function get_backend_header_value() {
  local domain="${1:-}" name="${2:-}" type="${3:-response}"
  domain="$(normalize_domain "$domain")"
  if [ -z "$domain" ]; then printf '\n'; return 0; fi
  _header_record_value "$BACKEND_HEADERS_FILE" backend "$domain" "$type" "$name"
}

function get_backend_proxy_ip_header() {
  local domain="${1:-}"
  _resolve_backend_ip_header "$domain" "$PROXY_IP_HEADER" "$BACKEND_PROXY_IP_HEADER_FILE" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" PROXY_IP_HEADER
}

function get_global_header_value() {
  _header_record_value "$CUSTOM_HEADERS_FILE" global '' "${2:-response}" "${1:-}"
}
