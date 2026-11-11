# shellcheck shell=bash

function _domain_config_legacy_read() {
  local file="${1:-}" header="${2:-}" callback="${3:-}" line="" line_no=0
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ -f "$file" ] || return 0
  [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      [ "${line%$'\r'}" = "$header" ] || { _domain_csv_error "$file" 1 'invalid legacy header'; return 1; }
      continue
    fi
    csv_parse_line "$line" || { _domain_csv_error "$file" "$line_no" "$CSV_PARSE_ERROR"; return 1; }
    "$callback" "$line_no" "${CSV_FIELDS[@]}" || return 1
  done <"$file"
}

function _domain_config_export_backend_row() {
  shift
  [ "${2:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
  local type="$1" upstream="$3" network="$4" port="${7:-}" protocol="${9:-}"
  local certificate="${10:-}" owner="" certificate_id="" path_id="" key="" value="" idx=0
  local -a row=("$@")
  case "$type" in
  backend)
    _dc_role=backend; _dc_backend_port="${upstream##*:}"; _dc_backend_network="$network"
    ;;
  port)
    if [ -n "$certificate" ] && [ "$certificate" != none ]; then
      if declare -F domain_config_cert_ref_split >/dev/null 2>&1; then
        domain_config_cert_ref_split owner certificate_id "$certificate" "$_dc_domain" || return 1
      else
        owner="${certificate%%/*}"; certificate_id="${certificate#*/}"
      fi
    fi
    if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
      csv_join_row "$port" "${row[7]}" "$protocol" "$owner" "$certificate_id" >>"$_dc_destination/ports.csv" || return 1
      for key in websocket redirect_enabled redirect_code http3_enabled alt_svc; do
        case "$key" in websocket) idx=10 ;; redirect_enabled) idx=11 ;; redirect_code) idx=12 ;; http3_enabled) idx=13 ;; alt_svc) idx=14 ;; esac
        value="${row[idx]}"
        [ -n "$value" ] || continue
        _domain_csv_set "$_dc_destination/port_options.csv" "$port" "$protocol" "$key" "$value" || return 1
      done
    else
      csv_join_row "$port" "${row[7]}" "$protocol" "$owner" "$certificate_id" "${row[10]:-no}" "${row[11]:-off}" "${row[12]}" "${row[13]:-off}" "${row[14]:-auto}" >>"$_dc_destination/ports.csv" || return 1
    fi
    ;;
  path)
    _dc_path_count=$((_dc_path_count + 1))
    _domain_config_export_path_identity "$port" "${row[4]}" || return 1
    path_id="$_dc_export_path_id"
    csv_join_row "$path_id" "$port" "${row[4]}" "${row[15]:-prefix}" "${row[16]:-100}" "${row[17]}" "${row[18]:-none}" "${row[5]}" >>"$_dc_destination/paths.csv" || return 1
    for key in websocket redirect_enabled redirect_code reason source_location; do
      case "$key" in websocket) idx=10 ;; redirect_enabled) idx=11 ;; redirect_code) idx=12 ;; reason) idx=19 ;; source_location) idx=20 ;; esac
      value="${row[idx]}"
      [ -n "$value" ] || continue
      _domain_csv_set "$_dc_destination/path_options.csv" "$path_id" "$key" "$value" || return 1
    done
    ;;
  *) return 1 ;;
  esac
}

function _domain_config_export_alias_row() {
  shift
  [ "${2:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq 3 ] || return 1
  _dc_role="$1"; _dc_target="$3"
}

function _domain_config_export_settings_row() {
  shift
  [ "${1:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq 2 ] || return 1
  local value="$2"
  case "$_dc_setting" in client_ip_header | proxy_ip_header) [ -n "$value" ] || value=off ;; esac
  _domain_csv_set "$_dc_destination/settings.csv" "$_dc_setting" "$value"
}

function _domain_config_export_header_row() {
  shift
  [ "${1:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq 4 ] || return 1
  shift
  csv_join_row "$@" >>"$_dc_destination/headers.csv"
}

function _domain_config_export_inheritance_row() {
  shift
  [ "${1:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq 6 ] || return 1
  shift
  local key=""
  for key in mtls acl security_rules headers paths; do
    _domain_csv_set "$_dc_destination/inheritance.csv" "$key" "$1" || return 1
    shift
  done
}

function _domain_config_export_directive_row() {
  shift
  [ "${2:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq 7 ] || return 1
  csv_join_row "$1" "$3" "$4" "$5" "$6" "$7" >>"$_dc_destination/nginx_directives.csv"
}

function _domain_config_export_mtls_row() {
  shift
  [ "${1:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq 2 ] || return 1
  _domain_csv_set "$_dc_destination/mtls.csv" enabled yes || return 1
  # The empty default denotes this domain's owned material without binding
  # declarative snapshots (and their backups) to this checkout's absolute path.
  _domain_csv_set "$_dc_destination/mtls.csv" directory ''
}

function _domain_config_export_docker_row() {
  shift
  [ "${1:-}" = "${_dc_domain}" ] || return 0
  [ "$#" -eq 2 ] || return 1
  local tokens="" token="" position=0
  _parse_docker_opts_capture_lines tokens "$2" 'persisted backend Docker options' || return 1
  [ -n "$tokens" ] || return 0
  while IFS= read -r token || [ -n "$token" ]; do
    position=$((position + 1))
    csv_join_row "$position" "$token" >>"$_dc_destination/docker_options.csv" || return 1
  done < <(printf '%s' "$tokens")
}

function _domain_config_export_rule_row() {
  local row_number="$1"
  shift
  [ "${2:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq "$STATE_SECURITY_RULES_COLS" ] || return 1
  local order=$((row_number - 1)) id="" i=0 base=0 content=""
  local -a row=("$@")
  content="$(csv_join_row "$@")" || return 1
  _domain_config_export_identity rule "$order" "$content" || return 1
  id="$_dc_export_identity"
  order="$_dc_export_order"
  if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" -lt 5 ]; then
    csv_join_row "$id" "$order" "${row[0]}" "${row[2]}" "${row[3]}" "${row[45]}" "${row[46]}" >>"$_dc_destination/security_rules.csv" || return 1
  else
    local action=""
    action="$(_sr_normalize_action "${row[47]:-}")" || return 1
    csv_join_row "$id" "$order" "${row[0]}" "$action" "${row[2]}" "${row[3]}" "${row[45]}" "${row[46]}" >>"$_dc_destination/security_rules.csv" || return 1
  fi
  for ((i = 0; i < ${row[4]}; i++)); do
    base=$((5 + i * 4))
    csv_join_row "$id" "$((i + 1))" "${row[base]}" "${row[base + 1]}" "${row[base + 2]}" "${row[base + 3]}" >>"$_dc_destination/security_conditions.csv" || return 1
  done
}

function _domain_config_export_acl_row() {
  local order=$((${1:-1} - 1))
  shift
  [ "${2:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || return 1
  local content=""
  content="$(csv_join_row "$@")" || return 1
  _domain_config_export_identity acl "$order" "$content" || return 1
  csv_join_row "$_dc_export_identity" "$_dc_export_order" "$1" "$3" "$4" "$5" "$6" >>"$_dc_destination/acl.csv"
}

function _domain_config_export_details_row() {
  shift 2
  [ "${1:-}" = "$_dc_domain" ] || return 0
  [ "$#" -eq 3 ] || return 1
  is_valid_image_ref "$2" || return 1
  case "$3" in running | stopped) ;; *) return 1 ;; esac
  if { [ -n "$_dc_image" ] && [ "$_dc_image" != "$2" ]; } ||
    { [ -n "$_dc_state" ] && [ "$_dc_state" != "$3" ]; }; then
    _domain_csv_error "$_dc_destination/backend.csv" 0 "backend details conflict with known image or lifecycle for ${_dc_domain}"
    return 1
  fi
  [ -n "$_dc_image" ] || _dc_image="$2"
  [ -n "$_dc_state" ] || _dc_state="$3"
  _dc_details_found=true
}

function _domain_config_export_backend_metadata() {
  local details_file="${1:-}" sidecar="${STATE_DIR}/domains/${_dc_domain}/runtime"
  local existing="$sidecar/applied" snapshot_status=0 identity_found=0
  local _dc_details_found=false unowned_online=false
  if [ -f "$sidecar/backend.csv" ]; then
    _dc_image="$(domain_config_get "$sidecar" backend.csv image)" || return 1
    _dc_state="$(domain_config_get "$sidecar" backend.csv state)" || return 1
  fi
  if [ -f "$existing/backend.csv" ]; then
    [ -n "$_dc_image" ] || _dc_image="$(domain_config_get "$existing" backend.csv image)" || return 1
    [ -n "$_dc_state" ] || _dc_state="$(domain_config_get "$existing" backend.csv state running)" || return 1
  fi
  # Schema 2 exports preserve the accepted specification without consulting
  # Docker. Migration first verifies any available immutable container identity;
  # operator details fill unavailable information and cannot override that proof.
  if ! domain_config_active; then
    if declare -F _backend_identity_read >/dev/null 2>&1; then
      _backend_identity_read "$_dc_domain" true || return 1
      identity_found="$BACKEND_IDENTITY_FOUND"
    fi
    if [ "${SKIP_DOCKER_CHECKS:-}" != true ] && command -v docker >/dev/null 2>&1 &&
      docker info >/dev/null 2>&1; then
      declare -F _backend_container_snapshot >/dev/null 2>&1 || return 1
      _backend_container_snapshot "$_dc_domain" 2>/dev/null || snapshot_status=$?
      case "$snapshot_status" in
      0)
        _dc_image="${BACKEND_CONTAINER_IMAGE:-}"
        case "${BACKEND_CONTAINER_STATUS:-}" in
        running) _dc_state=running ;;
        created | exited | dead | paused | restarting | removing) _dc_state=stopped ;;
        *) _domain_csv_error "$_dc_destination/backend.csv" 0 "cannot recover lifecycle for ${_dc_domain}"; return 1 ;;
        esac
        ;;
      1)
        if [ "$identity_found" -ne 0 ]; then
          _domain_csv_error "$_dc_destination/backend.csv" 0 "cannot verify saved container ownership for ${_dc_domain}"; return 1
        fi
        # Storage conversion needs no ownership of an existing legacy runtime.
        # Complete explicit details can describe the desired backend without
        # querying its name or granting permission to mutate that container.
        unowned_online=true
        ;;
      2) _backend_cleanup_snapshot "$_dc_domain" || return 1 ;;
      *) return 1 ;;
      esac
    fi
  fi
  if [ -n "$details_file" ]; then
    csv_read_records "$details_file" 'domain,image,state' _domain_config_export_details_row table || return 1
  fi
  if [ "$unowned_online" = true ] && [ "$_dc_details_found" != true ]; then
    _backend_cleanup_snapshot "$_dc_domain" || return 1
  fi
  is_valid_image_ref "$_dc_image" || {
    _domain_csv_error "$_dc_destination/backend.csv" 0 "cannot recover image for ${_dc_domain}"; return 1;
  }
  case "$_dc_state" in
  running | stopped) ;;
  *) _domain_csv_error "$_dc_destination/backend.csv" 0 "cannot recover lifecycle for ${_dc_domain}"; return 1 ;;
  esac
}

function domain_config_export_domain() {
  local _dc_domain="${1:-}" _dc_destination="${2:-}" details_file="${3:-}"
  local _dc_role=certificate-only _dc_target="" _dc_backend_port="" _dc_backend_network=""
  local _dc_image="" _dc_state="" _dc_setting="" _dc_path_count=0 key=""
  local _dc_export_path_id="" _dc_export_identity="" _dc_export_order="" _dc_used_ids="" _dc_current_contents=""
  local -a _dc_old_ids=() _dc_old_orders=() _dc_old_contents=()
  local -a _dc_new_contents=() _dc_export_ids_by_order=() _dc_export_orders_by_order=()
  is_valid_domain "$_dc_domain" && [ "$_dc_domain" = "$(normalize_domain "$_dc_domain")" ] || return 1
  _domain_csv_initialize "$_dc_destination" || return 1
  _domain_config_legacy_read "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" _domain_config_export_backend_row || return 1
  _domain_config_legacy_read "$BACKEND_ALIASES_FILE" "$STATE_BACKEND_ALIASES_HEADER" _domain_config_export_alias_row || return 1
  _domain_csv_set "$_dc_destination/domain.csv" schema_version "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" || return 1
  _domain_csv_set "$_dc_destination/domain.csv" role "$_dc_role" || return 1
  [ -z "$_dc_target" ] || _domain_csv_set "$_dc_destination/domain.csv" target "$_dc_target" || return 1
  if [ "$_dc_role" = backend ]; then
    _domain_config_export_backend_metadata "$details_file" || return 1
    _domain_csv_set "$_dc_destination/backend.csv" image "$_dc_image" || return 1
    _domain_csv_set "$_dc_destination/backend.csv" container_port "$_dc_backend_port" || return 1
    _domain_csv_set "$_dc_destination/backend.csv" network "${_dc_backend_network:-${DEFAULT_NETWORK:-dockistrate-net}}" || return 1
    _domain_csv_set "$_dc_destination/backend.csv" state "$_dc_state" || return 1
  fi
  for _dc_setting in http_version client_ip_header proxy_ip_header acl_policy acl_status security_rule_status; do
    _domain_csv_setting_spec "$_dc_setting" || return 1
    _domain_config_legacy_read "$CONFIG_DIR/$DC_SETTING_FILE" "$DC_SETTING_HEADER" _domain_config_export_settings_row || return 1
  done
  _domain_config_legacy_read "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" _domain_config_export_header_row || return 1
  _domain_config_legacy_read "$CONFIG_DIR/dedicated_host_inheritance.csv" "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" _domain_config_export_inheritance_row || return 1
  _domain_config_legacy_read "$NGINX_DIRECTIVES_FILE" "$STATE_NGINX_DIRECTIVES_HEADER" _domain_config_export_directive_row || return 1
  _domain_config_legacy_read "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" _domain_config_export_mtls_row || return 1
  _domain_config_legacy_read "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER" _domain_config_export_docker_row || return 1
  _domain_config_export_identity_prepare rule || return 1
  _domain_config_legacy_read "$SECURITY_RULES_FILE" "$STATE_SECURITY_RULES_HEADER" _domain_config_export_rule_row || return 1
  _domain_config_export_identity_prepare acl || return 1
  _domain_config_legacy_read "$SECURITY_IP_RULES_FILE" "$STATE_SECURITY_IP_RULES_HEADER" _domain_config_export_acl_row || return 1
  if declare -F domain_config_export_certificates >/dev/null 2>&1; then
    domain_config_export_certificates "$_dc_domain" "$_dc_destination" || return 1
  fi
}
