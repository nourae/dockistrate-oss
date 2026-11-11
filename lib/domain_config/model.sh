# shellcheck shell=bash

if ! declare -F _domain_csv_normalize_record_numbers >/dev/null 2>&1; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/numeric_values.sh"
fi

# Editable domain files are data, never shell programs. Keep schemas centralized
# so validation, serialization, and the legacy-state adapter share one contract.
function domain_config_files() {
  case "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" in
  3) printf '%s\n' domain.csv backend.csv settings.csv inheritance.csv ports.csv port_options.csv paths.csv path_options.csv headers.csv docker_options.csv nginx_directives.csv security_rules.csv security_conditions.csv acl.csv mtls.csv certificates.csv certificate_options.csv ;;
  4 | 5) printf '%s\n' domain.csv backend.csv settings.csv inheritance.csv ports.csv paths.csv path_options.csv headers.csv docker_options.csv nginx_directives.csv security_rules.csv security_conditions.csv acl.csv mtls.csv certificates.csv ;;
  *) _domain_csv_error '' 0 'unsupported input schema version' ;;
  esac
}

function _domain_csv_schema() {
  DOMAIN_CSV_COLS=2 DOMAIN_CSV_CARDINALITY=table DOMAIN_CSV_KEYS=-1
  case "${1:-}" in
  domain.csv) DOMAIN_CSV_HEADER='schema_version,role,target'; DOMAIN_CSV_CARDINALITY=singleton; DOMAIN_CSV_KEYS=0 ;;
  backend.csv) DOMAIN_CSV_HEADER='image,container_port,network,state'; DOMAIN_CSV_CARDINALITY=singleton; DOMAIN_CSV_KEYS=0 ;;
  settings.csv) DOMAIN_CSV_HEADER='http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status'; DOMAIN_CSV_CARDINALITY=singleton; DOMAIN_CSV_KEYS=0 ;;
  inheritance.csv) DOMAIN_CSV_HEADER='mtls,acl,security_rules,headers,paths'; DOMAIN_CSV_CARDINALITY=singleton; DOMAIN_CSV_KEYS=0 ;;
  mtls.csv) DOMAIN_CSV_HEADER='enabled,directory'; DOMAIN_CSV_CARDINALITY=singleton; DOMAIN_CSV_KEYS=0 ;;
  ports.csv)
    DOMAIN_CSV_HEADER='listen_port,upstream_port,protocol,certificate_owner,certificate_id'
    [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ] || DOMAIN_CSV_HEADER+=',websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc'
    ;;
  port_options.csv)
    [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ] || { _domain_csv_error "${1:-}" 0 'listener options belong in ports.csv'; return 1; }
    DOMAIN_CSV_HEADER='listen_port,protocol,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc'; DOMAIN_CSV_KEYS=2
    ;;
  paths.csv) DOMAIN_CSV_HEADER='path_id,listen_port,path_prefix,match,priority,target,rewrite,header_set' ;;
  path_options.csv) DOMAIN_CSV_HEADER='path_id,websocket,redirect_enabled,redirect_code,reason,source_location'; DOMAIN_CSV_KEYS=1 ;;
  headers.csv) DOMAIN_CSV_HEADER='header_type,header_name,header_value' ;;
  docker_options.csv) DOMAIN_CSV_HEADER='position,argument' ;;
  nginx_directives.csv) DOMAIN_CSV_HEADER='scope,listen_port,path_prefix,directive_mode,directive_name,directive_value' ;;
  security_rules.csv)
    if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" -lt 5 ]; then
      DOMAIN_CSV_HEADER='rule_id,order,enabled,mode,status_code,reason,source_location'
    else
      DOMAIN_CSV_HEADER='rule_id,order,enabled,action,mode,status_code,reason,source_location'
    fi
    ;;
  security_conditions.csv) DOMAIN_CSV_HEADER='rule_id,condition_order,selector,name,operator,value' ;;
  acl.csv) DOMAIN_CSV_HEADER='rule_id,order,enabled,scope,action,ip_value,status_code' ;;
  certificates.csv)
    DOMAIN_CSV_HEADER='certificate_id,provider,port_suffix'
    [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ] || DOMAIN_CSV_HEADER+=',source_fullchain,source_privkey'
    ;;
  certificate_options.csv)
    [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ] || { _domain_csv_error "${1:-}" 0 'certificate import settings belong in certificates.csv'; return 1; }
    DOMAIN_CSV_HEADER='certificate_id,source_fullchain,source_privkey'; DOMAIN_CSV_KEYS=1
    ;;
  *) echo "[Error] Unknown domain configuration file: ${1:-}" >&2; return 1 ;;
  esac
  local rest="$DOMAIN_CSV_HEADER"
  DOMAIN_CSV_COLS=1
  while [ "${rest#*,}" != "$rest" ]; do DOMAIN_CSV_COLS=$((DOMAIN_CSV_COLS + 1)); rest="${rest#*,}"; done
}

function _domain_csv_error() {
  echo "[Error] ${1:-domain configuration}:${2:-0}: ${3:-invalid configuration}" >&2
  return 1
}

# All on-disk files contain complete named records. The internal callback
# interface expands settings records into individual values, letting existing
# validators/compiler helpers share the same field-level semantics.
function _domain_csv_read() {
  local file="${1:-}" _dc_record_callback="${2:-}" _dc_record_keys=0 _dc_record_seen=$'\n'
  _domain_csv_schema "${file##*/}" || return 1
  _dc_record_keys="$DOMAIN_CSV_KEYS"
  if [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" = true ]; then
    local header=""
    if [ -f "$file" ]; then IFS= read -r header <"$file" || true; fi
    case "${header%$'\r'}" in
    key,value | listen_port,protocol,key,value | path_id,key,value | certificate_id,key,value)
      _domain_csv_read_v2 "$file" "$_dc_record_callback"; return $? ;;
    esac
  fi
  csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_expand_record "$DOMAIN_CSV_CARDINALITY"
}

function _domain_csv_expand_record() {
  local file="$1" line_no="$2" i=0 key="" value="" identity=""
  shift 2
  local -a values=("$@") ids=()
  _domain_csv_normalize_record_numbers "$file" || return 1
  if [ "$_dc_record_keys" -lt 0 ]; then
    _domain_csv_check_record_identity "$file" "$line_no" "${values[@]}" || return 1
    if [ "${file##*/}" = ports.csv ] && [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" != 3 ]; then
      values[5]="${values[5]:-no}"
      values[6]="${values[6]:-off}"
      values[8]="${values[8]:-off}"
      values[9]="${values[9]:-auto}"
    fi
    if [ "${file##*/}" = security_rules.csv ]; then
      if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" -lt 5 ]; then
        values=("${values[@]:0:3}" require "${values[@]:3}")
      else
        values[3]="${values[3]:-require}"
      fi
    fi
    "$_dc_record_callback" "$file" "$line_no" "${values[@]}"; return $?
  fi
  for ((i = 0; i < _dc_record_keys; i++)); do ids+=("${values[i]}"); done
  if [ "$_dc_record_keys" -gt 0 ]; then
    identity="$(csv_join_row "${ids[@]}")" || return 1
    case "$_dc_record_seen" in *$'\n'"$identity"$'\n'*) _domain_csv_error "$file" "$line_no" 'duplicate logical record'; return 1 ;; esac
    _dc_record_seen="${_dc_record_seen}${identity}"$'\n'
  fi
  for ((i = _dc_record_keys; i < ${#values[@]}; i++)); do
    key="${CSV_RECORD_HEADERS[i]}"; value="${values[i]}"
    if [ -z "$value" ]; then
      case "${file##*/}:$key" in
      domain.csv:schema_version | domain.csv:role | backend.csv:image | backend.csv:container_port) ;;
      port_options.csv:websocket) value=no ;;
      port_options.csv:redirect_enabled | port_options.csv:http3_enabled) value=off ;;
      port_options.csv:alt_svc) value=auto ;;
      path_options.csv:websocket | path_options.csv:redirect_enabled) value=inherit ;;
      path_options.csv:reason) value=- ;;
      path_options.csv:source_location) value=auto ;;
      port_options.csv:* | path_options.csv:* | certificate_options.csv:*) ;;
      *) continue ;;
      esac
    fi
    "$_dc_record_callback" "$file" "$line_no" "${ids[@]+"${ids[@]}"}" "$key" "$value" || return 1
  done
}

function _domain_csv_emit_row() {
  shift 2
  csv_join_row "$@"
}

function _domain_csv_rows() {
  _domain_csv_read "${1:-}" _domain_csv_emit_row
}

function _domain_csv_get_row() {
  if [ "${3:-}" = "$_dc_get_key" ]; then
    _dc_get_value="${4:-}"
  fi
}

function domain_config_get() {
  local config_dir="${1:-}" filename="${2:-}" _dc_get_key="${3:-}" _dc_get_value="${4:-}"
  _domain_csv_read "$config_dir/$filename" _domain_csv_get_row || return 1
  printf '%s\n' "$_dc_get_value"
}

function _domain_csv_lookup_row() {
  local file="$1" line_no="$2"
  shift 2
  local index=0 matched=true
  for ((index = 0; index < ${#_dc_lookup_keys[@]}; index++)); do
    [ "${1:-}" = "${_dc_lookup_keys[index]}" ] || matched=false
    shift || true
  done
  if [ "$matched" = true ]; then
    _dc_lookup_result="${1:-}"
  fi
  : "$file" "$line_no"
}

function _domain_csv_lookup() {
  local file="${1:-}" default="${2:-}" _dc_lookup_result="${2:-}"
  shift 2
  local -a _dc_lookup_keys=("$@")
  _domain_csv_read "$file" _domain_csv_lookup_row || return 1
  printf '%s\n' "${_dc_lookup_result:-$default}"
}

function domain_config_docker_options() {
  local config_dir="${1:-}" rows="" line="" result="" token=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  rows="$(_domain_csv_rows "$config_dir/docker_options.csv")" || return 1
  [ -n "$rows" ] || { printf '\n'; return 0; }
  rows="$(printf '%s\n' "$rows" | LC_ALL=C sort -t, -k1,1n)" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    csv_parse_line "$line" || return 1
    token="$(_docker_opts_quote_token "${CSV_FIELDS[1]}")" || return 1
    result="${result}${result:+ }${token}"
  done <<<"$rows"
  printf '%s\n' "$result"
}

function _domain_csv_entity_key_indexes() {
  DOMAIN_CSV_KEY_INDEXES=()
  case "${1:-}" in
  ports.csv) DOMAIN_CSV_KEY_INDEXES=(0 2) ;;
  certificates.csv) DOMAIN_CSV_KEY_INDEXES=(0) ;;
  *)
    local i=0
    [ "$DOMAIN_CSV_KEYS" -ge 0 ] || return 1
    for ((i = 0; i < DOMAIN_CSV_KEYS; i++)); do DOMAIN_CSV_KEY_INDEXES+=("$i"); done
    ;;
  esac
}

function _domain_csv_entity_field_row() {
  shift 2
  local i=0
  local -a values=("$@")
  for ((i = 0; i < ${#_dc_entity_ids[@]}; i++)); do
    [ "${values[${_dc_entity_indexes[i]}]}" = "${_dc_entity_ids[i]}" ] || return 0
  done
  _dc_entity_value="${values[_dc_entity_field_index]}"
}

function _domain_csv_entity_field() {
  local file="$1" field="$2" fallback="${3:-}" i=0 _dc_entity_field_index=-1 _dc_entity_value="${3:-}"
  local -a CSV_FIELDS=() DOMAIN_CSV_KEY_INDEXES=() _dc_entity_indexes=() _dc_entity_ids=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  shift 3
  _domain_csv_schema "${file##*/}" && _domain_csv_entity_key_indexes "${file##*/}" || return 1
  [ "$#" -eq "${#DOMAIN_CSV_KEY_INDEXES[@]}" ] || return 1
  _dc_entity_indexes=("${DOMAIN_CSV_KEY_INDEXES[@]}"); _dc_entity_ids=("$@")
  csv_parse_line "$DOMAIN_CSV_HEADER" || return 1
  for ((i = 0; i < ${#_dc_entity_ids[@]}; i++)); do
    case "${_dc_entity_ids[i]}" in
    0[0-9]* | *:0[0-9]*)
      _dc_entity_ids[i]="$(_domain_csv_normalize_number "$file" "${CSV_FIELDS[${_dc_entity_indexes[i]}]}" "${_dc_entity_ids[i]}")" || return 1
      ;;
    esac
  done
  for ((i = 0; i < ${#CSV_FIELDS[@]}; i++)); do
    [ "${CSV_FIELDS[i]}" != "$field" ] || _dc_entity_field_index="$i"
  done
  [ "$_dc_entity_field_index" -ge 0 ] || { _domain_csv_error "$file" 0 "unknown field $field"; return 1; }
  _domain_csv_read "$file" _domain_csv_entity_field_row || return 1
  printf '%s\n' "${_dc_entity_value:-$fallback}"
}

function domain_config_port_option() {
  if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
    _domain_csv_lookup "${1:-}/port_options.csv" "${5:-}" "${2:-}" "${3:-}" "${4:-}"
  else
    _domain_csv_entity_field "${1:-}/ports.csv" "${4:-}" "${5:-}" "${2:-}" "${3:-}"
  fi
}

function domain_config_certificate_option() {
  if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
    _domain_csv_lookup "${1:-}/certificate_options.csv" "${4:-}" "${2:-}" "${3:-}"
  else
    _domain_csv_entity_field "${1:-}/certificates.csv" "${3:-}" "${4:-}" "${2:-}"
  fi
}

function _domain_csv_setting_spec() {
  case "${1:-}" in
  http_version) DC_SETTING_FILE=backend_http_versions.csv; DC_SETTING_HEADER="$STATE_BACKEND_HTTP_VERSIONS_HEADER"; DC_SETTING_KEY=HTTP_VERSION ;;
  client_ip_header) DC_SETTING_FILE=backend_client_ip_headers.csv; DC_SETTING_HEADER="$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER"; DC_SETTING_KEY=CLIENT_IP_HEADER ;;
  proxy_ip_header) DC_SETTING_FILE=backend_proxy_ip_headers.csv; DC_SETTING_HEADER="$STATE_BACKEND_PROXY_IP_HEADERS_HEADER"; DC_SETTING_KEY=PROXY_IP_HEADER ;;
  acl_policy) DC_SETTING_FILE=backend_acl_policies.csv; DC_SETTING_HEADER="$STATE_BACKEND_ACL_POLICIES_HEADER"; DC_SETTING_KEY=ACL_POLICY ;;
  acl_status) DC_SETTING_FILE=backend_acl_statuses.csv; DC_SETTING_HEADER="$STATE_BACKEND_ACL_STATUSES_HEADER"; DC_SETTING_KEY=ACL_STATUS ;;
  security_rule_status) DC_SETTING_FILE=backend_security_rule_statuses.csv; DC_SETTING_HEADER="$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER"; DC_SETTING_KEY=SECURITY_RULE_STATUS ;;
  *) return 1 ;;
  esac
}

function _domain_csv_safe_id() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && [ "${#1}" -le 128 ]
}

function _domain_csv_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && [ "${#1}" -le 9 ]
}
