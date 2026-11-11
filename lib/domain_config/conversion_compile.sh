# shellcheck shell=bash

function _domain_config_compile_settings() {
  shift 2
  _domain_csv_setting_spec "$1" || return 1
  csv_join_row "$_dc_domain" "$2" >>"$_dc_output/$DC_SETTING_FILE"
}

function _domain_config_compile_headers() {
  local file="$1" line="$2"
  shift 2
  _header_rows_add "$file" "$line" "$_dc_domain" "$@" || return 1
  [ "$_header_row_added" = yes ] || return 0
  csv_join_row "$_dc_domain" "$@" >>"$_dc_output/backend_headers.csv"
}

function _domain_config_compile_directives() {
  shift 2
  csv_join_row "$1" "$_dc_domain" "$2" "$3" "$4" "$5" "$6" >>"$_dc_output/nginx_directives.csv"
}

function _domain_config_compile_port() {
  shift 2
  local port="$1" upstream="$2" protocol="$3" owner="$4" id="$5" reference="none"
  local ws="" redirect="" code="" http3="" alt_svc=""
  [ -z "$id" ] || reference="$owner/$id"
  if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
    ws="$(domain_config_port_option "$_dc_config" "$port" "$protocol" websocket no)" || return 1
    redirect="$(domain_config_port_option "$_dc_config" "$port" "$protocol" redirect_enabled off)" || return 1
    code="$(domain_config_port_option "$_dc_config" "$port" "$protocol" redirect_code '')" || return 1
    http3="$(domain_config_port_option "$_dc_config" "$port" "$protocol" http3_enabled off)" || return 1
    alt_svc="$(domain_config_port_option "$_dc_config" "$port" "$protocol" alt_svc auto)" || return 1
  else
    ws="$6"; redirect="$7"; code="$8"; http3="$9"; alt_svc="${10}"
  fi
  state_backend_ports_row_port "$_dc_domain" "$port" "$upstream" "$protocol" "$reference" "$ws" "$redirect" "$code" "$http3" "$alt_svc" >>"$_dc_output/backend_ports.csv"
}

function _domain_config_compile_path() {
  shift 2
  local id="$1" port="$2" prefix="$3" match="$4" priority="$5" target="$6" rewrite="$7" header="$8"
  local ws="" redirect="" code="" reason="" location=""
  ws="$(_domain_csv_lookup "$_dc_config/path_options.csv" inherit "$id" websocket)" || return 1
  redirect="$(_domain_csv_lookup "$_dc_config/path_options.csv" inherit "$id" redirect_enabled)" || return 1
  code="$(_domain_csv_lookup "$_dc_config/path_options.csv" '' "$id" redirect_code)" || return 1
  reason="$(_domain_csv_lookup "$_dc_config/path_options.csv" - "$id" reason)" || return 1
  location="$(_domain_csv_lookup "$_dc_config/path_options.csv" auto "$id" source_location)" || return 1
  state_backend_ports_row_path "$_dc_domain" "$prefix" "$header" "$port" "$ws" "$redirect" "$code" "${match:-prefix}" "${priority:-100}" "$target" "${rewrite:-none}" "$reason" "$location" >>"$_dc_output/backend_ports.csv"
}

function _domain_config_compile_condition() {
  shift 2
  [ "$1" = "$_dc_rule_id" ] || return 0
  local index=$((($2 - 1) * 4))
  _dc_conditions[index]="$3"; _dc_conditions[index + 1]="$4"
  _dc_conditions[index + 2]="$5"; _dc_conditions[index + 3]="$6"
  _dc_condition_count=$((_dc_condition_count + 1))
}

function _domain_config_compile_rule() {
  shift 2
  local order="$2" row=""
  row="$(_domain_config_rule_legacy_line "$_dc_config" "$_dc_domain" "$1" "$3" "$4" "$5" "$6" "$7" "$8")" || return 1
  printf '%s\t%s\n' "$order" "$row" >>"$_dc_output/.domain-security-rows"
}

function _domain_config_compile_acl() {
  shift 2
  local order="$2" row=""
  row="$(csv_join_row "$3" "$_dc_domain" "$4" "$5" "$6" "$7")" || return 1
  printf '%s\t%s\n' "$order" "$row" >>"$_dc_output/.domain-acl-rows"
}

function _domain_config_compile_observed_backend() {
  local line_no="$1" address="" upstream=""
  shift
  if [ "${1:-}" = backend ] && [ "${2:-}" = "$_dc_domain" ]; then
    upstream="${3:-}"; address="${upstream%:*}"
    if [ "$#" -ne "$STATE_BACKEND_PORTS_COLS" ] ||
      ! is_valid_ipv4 "$address" || ! is_valid_port "${upstream##*:}"; then
      [ "$_dc_backend_cache_tolerant" = true ] && return 0
      _domain_csv_error "$_dc_current_backend_ports" "$line_no" 'invalid legacy backend address'
      return 1
    fi
    [ "${4:-}" = "$network" ] || return 0
    if [ -n "$_dc_backend_ip_seen" ] && [ "$_dc_backend_ip_seen" != "$address" ]; then
      _dc_backend_ip_ambiguous=true
    else
      _dc_backend_ip_seen="$address"
      _dc_backend_ip="$address"
    fi
  fi
}

function _domain_config_compile_backend_address() {
  local observed="${DOMAINS_DIR:-${STATE_DIR}/domains}/${_dc_domain}/runtime/observed.csv"
  local address="" observed_network="" id="" token=""
  local BACKEND_IDENTITY_ID="" BACKEND_IDENTITY_TOKEN="" BACKEND_IDENTITY_FOUND=0
  local _dc_backend_ip_seen="" _dc_backend_ip_ambiguous=false _dc_backend_cache_tolerant=false
  _dc_backend_ip=127.0.0.1
  # Runtime observations are captured from verified full IDs. Compilation uses
  # saved data only and never queries Docker, including validation and previews.
  if [ -f "$observed" ] && [ ! -L "$observed" ] && [ ! -L "${observed%/*}" ] &&
    address="$(_domain_runtime_get "$observed" address 2>/dev/null)" && is_valid_ipv4 "$address" &&
    observed_network="$(_domain_runtime_get "$observed" network 2>/dev/null)" && [ "$observed_network" = "$network" ] &&
    id="$(_domain_runtime_get "$observed" container_id 2>/dev/null)" &&
    token="$(_domain_runtime_get "$observed" ownership_token 2>/dev/null)" &&
    _backend_identity_read "$_dc_domain" true 2>/dev/null && [ "$BACKEND_IDENTITY_FOUND" -eq 1 ] &&
    [ "$id" = "$BACKEND_IDENTITY_ID" ] && [ "$token" = "$BACKEND_IDENTITY_TOKEN" ]; then
    _dc_backend_ip="$address"
    return 0
  fi
  # Migration and explicit legacy replacement can precede observed metadata.
  # Keep an unambiguous valid saved route, but discard corrupt derived rows.
  if domain_config_active; then _dc_backend_cache_tolerant=true; fi
  if [ "$_dc_backend_cache_tolerant" = true ]; then
    if ! _domain_config_legacy_read "$_dc_current_backend_ports" "$STATE_BACKEND_PORTS_HEADER" _domain_config_compile_observed_backend 2>/dev/null; then
      _dc_backend_ip=127.0.0.1
    fi
  else
    _domain_config_legacy_read "$_dc_current_backend_ports" "$STATE_BACKEND_PORTS_HEADER" _domain_config_compile_observed_backend || return 1
  fi
  if [ "$_dc_backend_ip_ambiguous" = true ]; then
    _dc_backend_ip=127.0.0.1
    [ "$_dc_backend_cache_tolerant" = true ] || {
      _domain_csv_error "$_dc_current_backend_ports" 0 "ambiguous legacy backend address for $_dc_domain"; return 1;
    }
  fi
}

function _domain_config_compile_global_directive() {
  shift
  case "${1:-}" in global | stream-global) csv_join_row "$@" >>"$_dc_output/nginx_directives.csv" ;; esac
}

function _domain_config_compile_identity() {
  shift
  if [ -f "$_dc_root/${1:-}/config/domain.csv" ] &&
    [ "$(domain_config_get "$_dc_root/$1/config" domain.csv role)" = backend ]; then
    csv_join_row "$@" >>"$_dc_output/backend_identity.csv"
  fi
}

function _domain_config_compile_one() {
  local _dc_domain="$1" _dc_config="$_dc_root/$1/config" role="" target="" key="" value="" options=""
  local _dc_backend_ip=127.0.0.1 port="" network="" mtls_enabled="" mtls_directory=""
  local -a inheritance=()
  local -a _header_row_keys=() _header_row_owners=() _header_row_types=() _header_row_names=() _header_row_values=() _header_row_lines=()
  local _header_row_added=no _header_row_index=0
  role="$(domain_config_get "$_dc_config" domain.csv role)" || return 1
  target="$(domain_config_get "$_dc_config" domain.csv target)" || return 1
  case "$role" in
  backend)
    port="$(domain_config_get "$_dc_config" backend.csv container_port)" || return 1
    network="$(domain_config_get "$_dc_config" backend.csv network "${DEFAULT_NETWORK:-dockistrate-net}")" || return 1
    _domain_config_compile_backend_address || return 1
    state_backend_ports_row_backend "$_dc_domain" "$_dc_backend_ip:$port" "$network" >>"$_dc_output/backend_ports.csv" || return 1
    options="$(domain_config_docker_options "$_dc_config")" || return 1
    [ -z "$options" ] || csv_join_row "${_dc_domain}" "$options" >>"$_dc_output/backend_docker_opts.csv" || return 1
    ;;
  alias | dedicated)
    csv_join_row "$role" "$_dc_domain" "$target" >>"$_dc_output/backend_aliases.csv" || return 1
    if [ "$role" = dedicated ]; then
      for key in mtls acl security_rules headers paths; do
        value="$(domain_config_get "$_dc_config" inheritance.csv "$key" yes)" || return 1
        inheritance+=("$value")
      done
      csv_join_row "$_dc_domain" "${inheritance[@]}" >>"$_dc_output/dedicated_host_inheritance.csv" || return 1
    fi
    ;;
  esac
  _domain_csv_read "$_dc_config/settings.csv" _domain_config_compile_settings || return 1
  _domain_csv_read "$_dc_config/headers.csv" _domain_config_compile_headers || return 1
  _domain_csv_read "$_dc_config/ports.csv" _domain_config_compile_port || return 1
  _domain_csv_read "$_dc_config/paths.csv" _domain_config_compile_path || return 1
  _domain_csv_read "$_dc_config/nginx_directives.csv" _domain_config_compile_directives || return 1
  _domain_csv_read "$_dc_config/security_rules.csv" _domain_config_compile_rule || return 1
  _domain_csv_read "$_dc_config/acl.csv" _domain_config_compile_acl || return 1
  mtls_enabled="$(domain_config_get "$_dc_config" mtls.csv enabled no)" || return 1
  if [ "$mtls_enabled" = yes ]; then
    mtls_directory="$(domain_config_get "$_dc_config" mtls.csv directory "${STATE_DIR}/domains/${_dc_domain}/mtls")" || return 1
    [ -n "$mtls_directory" ] || mtls_directory="${STATE_DIR}/domains/${_dc_domain}/mtls"
    csv_join_row "$_dc_domain" "$mtls_directory" >>"$_dc_output/backend_mtls.csv" || return 1
  fi
}

function domain_config_compile() {
  local _dc_root="${1:-}" _dc_output="${2:-}" _dc_current_backend_ports="${BACKEND_PORTS_FILE:-}"
  local entry="" domain="" key="" filename=""
  [ -n "$_dc_output" ] && [ "$_dc_output" != "${CONFIG_DIR:-}" ] || return 1
  _domain_config_validate_source_tree "$_dc_root" || return 1
  [ ! -L "$_dc_output" ] || return 1
  mkdir -p "$_dc_output" || return 1
  # These files describe global/shared settings. Domain-owned files are rebuilt.
  for filename in global_settings.csv custom_headers.csv port_tls_protocols.csv port_tls_ciphers.csv access_log_fields.csv; do
    if [ -e "$CONFIG_DIR/$filename" ] || [ -L "$CONFIG_DIR/$filename" ]; then
      if [ ! -f "$CONFIG_DIR/$filename" ] || [ -L "$CONFIG_DIR/$filename" ]; then
        _domain_config_error "Shared configuration must be a regular file, not a symlink: $CONFIG_DIR/$filename"
        return 1
      fi
      cp "$CONFIG_DIR/$filename" "$_dc_output/$filename" || return 1
    fi
  done
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$_dc_output/backend_ports.csv" || return 1
  printf '%s\n' "$STATE_BACKEND_IDENTITY_HEADER" >"$_dc_output/backend_identity.csv" || return 1
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$_dc_output/backend_aliases.csv" || return 1
  printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" >"$_dc_output/dedicated_host_inheritance.csv" || return 1
  printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER" >"$_dc_output/backend_headers.csv" || return 1
  printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" >"$_dc_output/backend_mtls.csv" || return 1
  printf '%s\n' "$STATE_BACKEND_DOCKER_OPTS_HEADER" >"$_dc_output/backend_docker_opts.csv" || return 1
  printf '%s\n' "$STATE_NGINX_DIRECTIVES_HEADER" >"$_dc_output/nginx_directives.csv" || return 1
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$_dc_output/security_rules.csv" || return 1
  printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$_dc_output/security_ip_rules.csv" || return 1
  : >"$_dc_output/.domain-security-rows"; : >"$_dc_output/.domain-acl-rows"
  for key in http_version client_ip_header proxy_ip_header acl_policy acl_status security_rule_status; do
    _domain_csv_setting_spec "$key" || return 1
    printf '%s\n' "$DC_SETTING_HEADER" >"$_dc_output/$DC_SETTING_FILE" || return 1
  done
  _domain_config_legacy_read "$CONFIG_DIR/nginx_directives.csv" "$STATE_NGINX_DIRECTIVES_HEADER" _domain_config_compile_global_directive || return 1
  _domain_config_legacy_read "$CONFIG_DIR/backend_identity.csv" "$STATE_BACKEND_IDENTITY_HEADER" _domain_config_compile_identity || return 1
  for entry in "$_dc_root"/*; do
    [ -d "$entry" ] || continue
    domain="${entry##*/}"
    _domain_config_compile_one "$domain" || return 1
  done
  LC_ALL=C sort -n -k1,1 "$_dc_output/.domain-security-rows" | cut -f2- >>"$_dc_output/security_rules.csv" || return 1
  LC_ALL=C sort -n -k1,1 "$_dc_output/.domain-acl-rows" | cut -f2- >>"$_dc_output/security_ip_rules.csv" || return 1
  rm -f "$_dc_output/.domain-security-rows" "$_dc_output/.domain-acl-rows"
}
