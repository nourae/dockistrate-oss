# shellcheck shell=bash

function _domain_config_unique_key() {
  local key="${1:-}"
  case "$_dc_seen" in *$'\n'"$key"$'\n'*) _domain_csv_error "$_dc_file" "$_dc_line" 'duplicate logical row'; return 1 ;; esac
  _dc_seen="${_dc_seen}${key}"$'\n'
}

function _domain_config_validate_scalar() {
  local filename="$1" key="$2" value="$3"
  case "$filename:$key" in
  domain.csv:schema_version)
    [ "$value" = "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" ] || {
      [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ] && [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" = true ] && [ "$value" = 2 ];
    }
    ;;
  domain.csv:role) case "$value" in backend | alias | dedicated | certificate-only) return 0 ;; *) return 1 ;; esac ;;
  domain.csv:target) [ -z "$value" ] || { is_valid_domain "$value" && [ "$value" = "$(normalize_domain "$value")" ]; } ;;
  backend.csv:image) is_valid_image_ref "$value" ;;
  backend.csv:container_port) is_valid_port "$value" ;;
  backend.csv:network) is_valid_network_name "$value" ;;
  backend.csv:state) case "$value" in running | stopped) return 0 ;; *) return 1 ;; esac ;;
  settings.csv:*) _domain_csv_setting_spec "$key" && validate_persisted_setting "$DC_SETTING_KEY" "$value" ;;
  inheritance.csv:mtls | inheritance.csv:acl | inheritance.csv:security_rules | inheritance.csv:headers | inheritance.csv:paths)
    case "$value" in yes | no) return 0 ;; *) return 1 ;; esac
    ;;
  mtls.csv:enabled) case "$value" in yes | no) return 0 ;; *) return 1 ;; esac ;;
  mtls.csv:directory)
    [ -z "$value" ] || [ "$value" = "${STATE_DIR}/domains/${_dc_domain}/mtls" ]
    ;;
  *) return 1 ;;
  esac
}

function _domain_config_validate_option() {
  local kind="$1" key="$2" value="$3"
  case "$kind:$key" in
  port:websocket) case "$value" in yes | no) return 0 ;; *) return 1 ;; esac ;;
  path:websocket) case "$value" in yes | no | inherit) return 0 ;; *) return 1 ;; esac ;;
  port:redirect_enabled) case "$value" in on | off) return 0 ;; *) return 1 ;; esac ;;
  path:redirect_enabled) case "$value" in on | off | inherit) return 0 ;; *) return 1 ;; esac ;;
  port:redirect_code | path:redirect_code) [ -z "$value" ] || is_valid_redirect_code_spec "$value" ;;
  port:http3_enabled) is_valid_http3_flag "$value" ;;
  port:alt_svc) is_valid_alt_svc_mode "$value" ;;
  path:reason) is_valid_reason_value "$value" ;;
  path:source_location) is_valid_loc_value "$value" ;;
  *) return 1 ;;
  esac
}

function _domain_config_validate_row() {
  local _dc_file="$1" _dc_line="$2" filename="${1##*/}" field="" key="" selector=""
  shift 2
  for field in "$@"; do
    case "$field" in *$'\r'* | *$'\n'*) _domain_csv_error "$_dc_file" "$_dc_line" 'multiline cells are not supported'; return 1 ;; esac
  done
  case "$filename" in
  domain.csv | backend.csv | settings.csv | inheritance.csv | mtls.csv)
    _domain_config_validate_scalar "$filename" "$1" "$2" || { _domain_csv_error "$_dc_file" "$_dc_line" "invalid ${1} setting"; return 1; }
    key="$1"
    ;;
  ports.csv)
    is_valid_port "$1" && is_valid_port "$2" && is_valid_protocol "$3" || return 1
    if [ "$3" = https ]; then
      is_valid_domain "$4" && [ "$4" = "$(normalize_domain "$4")" ] && _domain_csv_safe_id "$5" || return 1
    else
      [ -z "$4$5" ] || return 1
    fi
    validate_http_port_combination "$3" "$1" || return 1
    if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" != 3 ]; then
      _domain_config_validate_option port websocket "$6" &&
        _domain_config_validate_option port redirect_enabled "$7" &&
        _domain_config_validate_option port redirect_code "$8" &&
        _domain_config_validate_option port http3_enabled "$9" &&
        _domain_config_validate_option port alt_svc "${10}" || return 1
    fi
    key="$1:$3"
    ;;
  port_options.csv)
    is_valid_port "$1" && is_valid_protocol "$2" && _domain_config_validate_option port "$3" "$4" || return 1
    key="$1:$2:$3"
    ;;
  paths.csv)
    _domain_csv_safe_id "$1" && is_valid_port "$2" && is_valid_path_prefix "$3" || return 1
    is_valid_path_match_mode "${4:-prefix}" && is_valid_path_priority "${5:-100}" || return 1
    [ -z "$6" ] || is_valid_path_target "$6" || return 1
    is_valid_path_rewrite_spec "${7:-none}" || return 1
    [ -z "$8" ] || is_valid_header_set_name "$8" || return 1
    _domain_config_unique_key "path:$2:$3" || return 1
    key="id:$1"
    ;;
  path_options.csv)
    _domain_csv_safe_id "$1" && _domain_config_validate_option path "$2" "$3" || return 1
    key="$1:$2"
    ;;
  headers.csv)
    _header_rows_add "$_dc_file" "$_dc_line" "$_dc_domain" "$1" "$2" "$3"
    return $?
    ;;
  docker_options.csv)
    _domain_csv_positive_integer "$1" || return 1
    key="$1"
    ;;
  nginx_directives.csv)
    case "$1" in backend | port | path | stream-backend | stream-port) ;; *) return 1 ;; esac
    case "$4" in managed | raw) ;; *) return 1 ;; esac
    nginx_directive_validate_name_token "$5" && nginx_directive_validate_raw_value "$6" || return 1
    case "$1" in
    backend | stream-backend) [ -z "$2$3" ] || return 1 ;;
    port | stream-port) is_valid_port "$2" && [ -z "$3" ] || return 1 ;;
    path) is_valid_port "$2" && is_valid_path_prefix "$3" || return 1 ;;
    esac
    if [ "$4" = managed ]; then nginx_directive_catalog_validate_for_scope "$1" "$5" "$6" || return 1; fi
    key="$(csv_join_row "$1" "$2" "$3" "$5")" || return 1
    ;;
  security_rules.csv)
    _domain_csv_safe_id "$1" && _domain_csv_positive_integer "$2" || return 1
    case "$3" in 0 | 1) ;; *) return 1 ;; esac
    _sr_normalize_action "$4" >/dev/null || return 1
    case "$5" in single | and | or) ;; *) return 1 ;; esac
    [ -z "$6" ] || [ "$6" = - ] || is_status_code "$6" || return 1
    is_valid_reason_value "${7:--}" && is_valid_loc_value "${8:-auto}" || return 1
    _domain_config_unique_key "order:$2" || return 1
    key="id:$1"
    ;;
  security_conditions.csv)
    _domain_csv_safe_id "$1" && _domain_csv_positive_integer "$2" && [ "$2" -le 10 ] || return 1
    case "$3" in header | cookie | arg | method | scheme | host | path | uri | ip | tls_sni | tls_protocol | var) ;; *) return 1 ;; esac
    selector="$(_sr_source_to_selector "$3" "$4")" || return 1
    _sr_validate_rule_triplet "$selector" "$5" "$6" "$_dc_file:$_dc_line" || return 1
    key="$1:$2"
    ;;
  acl.csv)
    _domain_csv_safe_id "$1" && _domain_csv_positive_integer "$2" || return 1
    case "$3" in 0 | 1) ;; *) return 1 ;; esac
    case "$4" in l7 | l3 | both) ;; *) return 1 ;; esac
    case "$5" in allow | deny) ;; *) return 1 ;; esac
    _persisted_acl_validate_row "$_dc_line" "$_dc_domain" "$4" "$5" "$6" "$7" http || return 1
    _domain_config_unique_key "order:$2" || return 1
    key="id:$1"
    ;;
  certificates.csv)
    _domain_csv_safe_id "$1" && is_valid_port "$3" || return 1
    case "$2" in selfsigned | letsencrypt | custom) ;; *) return 1 ;; esac
    key="$1"
    ;;
  certificate_options.csv)
    _domain_csv_safe_id "$1" || return 1
    case "$2" in source_fullchain | source_privkey) ;; *) return 1 ;; esac
    key="$1:$2"
    ;;
  esac
  _domain_config_unique_key "$key"
}

function _domain_config_has_row() {
  local file="$1" column="$2" expected="$3" rows="" line=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  rows="$(_domain_csv_rows "$file")" || return 2
  [ -n "$rows" ] || return 1
  while IFS= read -r line; do
    csv_parse_line "$line" || return 2
    [ "${CSV_FIELDS[column]}" != "$expected" ] || return 0
  done <<<"$rows"
  return 1
}

function _domain_config_validate_condition_ref() {
  shift 2
  _domain_config_has_row "$_dc_config/security_rules.csv" 0 "$1"
}

function _domain_config_validate_rule_conditions() {
  shift 2
  local _dc_rule_id="$1" mode="$5" _dc_condition_count=0 i=0
  local -a _dc_conditions=()
  _domain_csv_read "$_dc_config/security_conditions.csv" _domain_config_compile_condition || return 1
  [ "$_dc_condition_count" -ge 1 ] && [ "$_dc_condition_count" -le 10 ] || return 1
  if [ "$_dc_condition_count" -eq 1 ]; then [ "$mode" = single ] || return 1; else [ "$mode" != single ] || return 1; fi
  for ((i = 0; i < _dc_condition_count * 4; i++)); do [ "${_dc_conditions[i]+present}" = present ] || return 1; done
}

function _domain_config_validate_path_option_ref() {
  shift 2
  _domain_config_has_row "$_dc_config/paths.csv" 0 "$1"
}

function _domain_config_validate_port_option_ref() {
  shift 2
  local wanted_port="$1" wanted_protocol="$2" rows="" line=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  rows="$(_domain_csv_rows "$_dc_config/ports.csv")" || return 1
  [ -n "$rows" ] || return 1
  while IFS= read -r line; do
    csv_parse_line "$line" || return 1
    if [ "${CSV_FIELDS[0]}" = "$wanted_port" ] && [ "${CSV_FIELDS[2]}" = "$wanted_protocol" ]; then return 0; fi
  done <<<"$rows"
  return 1
}

function _domain_config_validate_certificate_option_ref() {
  shift 2
  _domain_config_has_row "$_dc_config/certificates.csv" 0 "$1"
}

function _domain_config_validate_certificate_options() {
  shift 2
  local source_cert="" source_key="" material="" fingerprint="" material_root="${DOMAINS_DIR:-${STATE_DIR}/domains}" pair_mode="" source_file=certificates.csv
  if [ "${DOMAIN_CONFIG_RESTORE_MATERIAL:-}" = true ]; then
    material_root="${DOMAIN_CONFIG_RESTORE_MATERIAL_ROOT:-$material_root}"
    pair_mode=restore
  fi
  if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
    source_file=certificate_options.csv
    source_cert="$(domain_config_certificate_option "$_dc_config" "$1" source_fullchain)" || return 1
    source_key="$(domain_config_certificate_option "$_dc_config" "$1" source_privkey)" || return 1
  else
    source_cert="$4"; source_key="$5"
  fi
  case "$2" in
  custom)
    if [ -n "$source_cert$source_key" ]; then
      [ -n "$source_cert" ] && [ -n "$source_key" ] || return 1
      [ "${DOMAIN_CONFIG_VALIDATE_MATERIAL:-true}" != false ] || return 0
      material="${material_root}/${_dc_domain}/certs/$1"
      fingerprint="$(_domain_cert_fingerprint "$1" "$2" "$3" "$source_cert" "$source_key")" || return 1
      if ! _domain_cert_matches_specification "$material" "$fingerprint" "$pair_mode"; then
        [ -f "$source_cert" ] && [ -r "$source_cert" ] && [ -f "$source_key" ] && [ -r "$source_key" ] || {
          _domain_csv_error "$_dc_config/$source_file" 0 'custom certificate import sources are unavailable and no matching managed material exists'; return 1;
        }
      fi
    else
      [ "${DOMAIN_CONFIG_VALIDATE_MATERIAL:-true}" != false ] || return 0
      material="${material_root}/${_dc_domain}/certs/$1"
      if [ ! -f "$material/fullchain.pem" ] || [ ! -f "$material/privkey.pem" ]; then
        material="${CERTS_DIR}/custom/live/${_dc_domain}_$3"
        [ -f "$material/fullchain.pem" ] && [ -f "$material/privkey.pem" ] || {
          _domain_csv_error "$_dc_config/$source_file" 0 'custom certificate requires source_fullchain and source_privkey'; return 1;
        }
      fi
    fi
    ;;
  *) [ -z "$source_cert$source_key" ] || return 1 ;;
  esac
}

function domain_config_validate_source() {
  local DOMAIN_CONFIG_VALIDATE_MATERIAL=false
  domain_config_validate_directory "$@"
}

function _domain_config_validate_alias_setting() {
  case "${3:-}" in
  acl_policy | acl_status | security_rule_status) return 0 ;;
  *) _domain_csv_error "$1" "$2" "ordinary aliases inherit ${3:-this setting}; configure the target backend or use a dedicated host" ;;
  esac
}

function domain_config_validate_directory() {
  local _dc_domain="${1:-}" _dc_config="${2:-}" filename="" _dc_seen="" rows="" role="" target="" field="" options=""
  local -a _header_row_keys=() _header_row_owners=() _header_row_types=() _header_row_names=() _header_row_values=() _header_row_lines=()
  local _header_row_added=no _header_row_index=0
  is_valid_domain "$_dc_domain" && [ "$_dc_domain" = "$(normalize_domain "$_dc_domain")" ] || return 1
  [ -d "$_dc_config" ] && [ ! -L "$_dc_config" ] || return 1
  for filename in "$_dc_config"/* "$_dc_config"/.[!.]* "$_dc_config"/..?*; do
    [ -e "$filename" ] || [ -L "$filename" ] || continue
    _domain_csv_schema "${filename##*/}" || return 1
  done
  while IFS= read -r filename; do
    _dc_seen=$'\n'
    _domain_csv_read "$_dc_config/$filename" _domain_config_validate_row || {
      _domain_csv_error "$_dc_config/$filename" 0 'invalid domain source table'; return 1;
    }
  done < <(domain_config_files)
  _domain_config_validate_scalar domain.csv schema_version "$(domain_config_get "$_dc_config" domain.csv schema_version)" || return 1
  role="$(domain_config_get "$_dc_config" domain.csv role)" || return 1
  target="$(domain_config_get "$_dc_config" domain.csv target)" || return 1
  case "$role" in
  backend)
    [ -z "$target" ] || return 1
    for field in image container_port; do [ -n "$(domain_config_get "$_dc_config" backend.csv "$field")" ] || return 1; done
    ;;
  alias | dedicated) [ -n "$target" ] && [ "$target" != "$_dc_domain" ] || return 1 ;;
  certificate-only) [ -z "$target" ] || return 1 ;;
  *) return 1 ;;
  esac
  if [ "$role" != backend ]; then
    for filename in backend.csv docker_options.csv ports.csv port_options.csv; do
      if [ "$filename" = port_options.csv ] && [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" != 3 ]; then continue; fi
      rows="$(_domain_csv_rows "$_dc_config/$filename")" || return 1
      [ -z "$rows" ] || { _domain_csv_error "$_dc_config/$filename" 0 'only backends may own this table'; return 1; }
    done
  fi
  if [ "$role" != dedicated ]; then
    rows="$(_domain_csv_rows "$_dc_config/inheritance.csv")" || return 1
    [ -z "$rows" ] || { _domain_csv_error "$_dc_config/inheritance.csv" 0 'only dedicated hosts may configure inheritance'; return 1; }
  fi
  if [ "$role" = alias ]; then
    _domain_csv_read "$_dc_config/settings.csv" _domain_config_validate_alias_setting || return 1
    for filename in paths.csv path_options.csv nginx_directives.csv mtls.csv; do
      rows="$(_domain_csv_rows "$_dc_config/$filename")" || return 1
      [ -z "$rows" ] || {
        _domain_csv_error "$_dc_config/$filename" 0 'ordinary aliases inherit this configuration; configure the target backend or use a dedicated host'; return 1;
      }
    done
  fi
  if [ "$role" = certificate-only ]; then
    for filename in settings.csv inheritance.csv paths.csv path_options.csv headers.csv nginx_directives.csv security_rules.csv security_conditions.csv acl.csv mtls.csv; do
      rows="$(_domain_csv_rows "$_dc_config/$filename")" || return 1
      [ -z "$rows" ] || return 1
    done
  fi
  options="$(domain_config_docker_options "$_dc_config")" || return 1
  if [ -n "$options" ]; then normalize_docker_opts_for_storage "$options" "domain '${_dc_domain}' Docker options" backend >/dev/null || return 1; fi
  _domain_csv_read "$_dc_config/security_conditions.csv" _domain_config_validate_condition_ref || return 1
  _domain_csv_read "$_dc_config/security_rules.csv" _domain_config_validate_rule_conditions || return 1
  _domain_csv_read "$_dc_config/path_options.csv" _domain_config_validate_path_option_ref || return 1
  if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
    _domain_csv_read "$_dc_config/port_options.csv" _domain_config_validate_port_option_ref || return 1
    _domain_csv_read "$_dc_config/certificate_options.csv" _domain_config_validate_certificate_option_ref || return 1
  fi
  _domain_csv_read "$_dc_config/certificates.csv" _domain_config_validate_certificate_options || return 1
}
