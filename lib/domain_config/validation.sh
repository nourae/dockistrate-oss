# shellcheck shell=bash

function _domain_config_validate_global_order() {
  local filename="${1##*/}" order="${4:-}" id="${3:-}"
  case "$_dc_tree_orders" in *$'\n'"$filename:$order"$'\n'*) _domain_csv_error "$1" "$2" 'duplicate global rule order'; return 1 ;; esac
  case "$_dc_tree_ids" in *$'\n'"$filename:$id"$'\n'*) _domain_csv_error "$1" "$2" 'duplicate global rule ID'; return 1 ;; esac
  _dc_tree_orders="${_dc_tree_orders}${filename}:${order}"$'\n'
  _dc_tree_ids="${_dc_tree_ids}${filename}:${id}"$'\n'
}

function _domain_config_register_listener() {
  local port="$1" transport="$2" protocol="$3" i=0
  for ((i = 0; i < ${#_dc_listener_keys[@]}; i++)); do
    if [ "${_dc_listener_keys[i]}" = "$port/$transport" ]; then
      case "$protocol" in
      http | https | quic) [ "${_dc_listener_protocols[i]}" = "$protocol" ] && return 0 ;;
      esac
      _domain_csv_error "$_dc_config/ports.csv" 0 "conflicting listener ${port}/${transport} between ${_dc_listener_domains[i]} and ${_dc_domain}"
      return 1
    fi
  done
  _dc_listener_keys+=("$port/$transport"); _dc_listener_protocols+=("$protocol"); _dc_listener_domains+=("$_dc_domain")
}

function _domain_config_validate_port_refs() {
  shift 2
  local port="$1" protocol="$3" owner="$4" certificate="$5" transport=tcp http3=""
  [ "$protocol" != udp ] || transport=udp
  _domain_config_register_listener "$port" "$transport" "$protocol" || return 1
  if [ "$protocol" = https ]; then
    [ -d "$_dc_root/$owner/config" ] && _domain_config_has_row "$_dc_root/$owner/config/certificates.csv" 0 "$certificate" || {
      _domain_csv_error "$_dc_config/ports.csv" 0 "unknown certificate ${owner}/${certificate}"; return 1;
    }
    if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
      http3="$(domain_config_port_option "$_dc_config" "$port" "$protocol" http3_enabled off)" || return 1
    else
      http3="$9"
    fi
    [ "$http3" != on ] || _domain_config_register_listener "$port" udp quic || return 1
  fi
}

function _domain_config_validate_path_refs() {
  shift 2
  local port="$2" listener_domain="$_dc_domain" rows="" line="" found=false
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  case "$_dc_role" in alias | dedicated) listener_domain="$_dc_target" ;; esac
  rows="$(_domain_csv_rows "$_dc_root/$listener_domain/config/ports.csv")" || return 1
  if [ -n "$rows" ]; then
    while IFS= read -r line; do
      csv_parse_line "$line" || return 1
      if [ "${CSV_FIELDS[0]}" = "$port" ]; then
        case "${CSV_FIELDS[2]}" in http | https) found=true ;; esac
      fi
    done <<<"$rows"
  fi
  [ "$found" = true ] || { _domain_csv_error "$_dc_config/paths.csv" 0 'path must reference an HTTP/HTTPS mapping'; return 1; }
}

function _domain_config_role_transition_row() {
  shift
  [ "${2:-}" = "$_dc_transition_domain" ] || return 0
  if [ "$_dc_previous_role" != backend ] || [ "${1:-}" = backend ]; then
    _dc_previous_role_present=true
  fi
}

# Role edits must not discard a managed container or hostname association.
# Explicit removal commands already removed their aggregate row before export,
# so those cleanup workflows can still retain a certificate-only owner.
function _domain_config_validate_role_transition() {
  local _dc_transition_domain="$1" role="$2" _dc_previous_role="" _dc_previous_role_present=false
  _dc_previous_role="$(domain_config_get "$(domain_config_root)/$1/runtime/applied" domain.csv role)" || return 1
  case "$_dc_previous_role:$role" in
  backend:backend | certificate-only:* | :*) return 0 ;;
  backend:*)
    _domain_config_legacy_read "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" _domain_config_role_transition_row || return 1
    if [ "$_dc_previous_role_present" = true ]; then
      _domain_csv_error "$_dc_config/domain.csv" 0 'remove the existing backend explicitly before changing its role'; return 1
    fi
    ;;
  alias:backend | dedicated:backend)
    _domain_config_legacy_read "$BACKEND_ALIASES_FILE" "$STATE_BACKEND_ALIASES_HEADER" _domain_config_role_transition_row || return 1
    if [ "$_dc_previous_role_present" = true ]; then
      _domain_csv_error "$_dc_config/domain.csv" 0 'remove the existing host association explicitly before changing its role to backend'; return 1
    fi
    ;;
  esac
}

function _domain_config_validate_source_tree() {
  local _dc_root="${1:-}" entry="" _dc_domain="" _dc_config="" _dc_role="" _dc_target="" target_role=""
  local _dc_tree_orders=$'\n' _dc_tree_ids=$'\n'
  local -a _dc_listener_keys=() _dc_listener_protocols=() _dc_listener_domains=() CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ -d "$_dc_root" ] && [ ! -L "$_dc_root" ] || return 1
  for entry in "$_dc_root"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ -d "$entry" ] && [ ! -L "$entry" ] || return 1
    _dc_domain="${entry##*/}"
    domain_config_validate_directory "$_dc_domain" "$entry/config" || return 1
  done
  for entry in "$_dc_root"/*; do
    [ -d "$entry" ] || continue
    _dc_domain="${entry##*/}"; _dc_config="$entry/config"
    _dc_role="$(domain_config_get "$_dc_config" domain.csv role)" || return 1
    _dc_target="$(domain_config_get "$_dc_config" domain.csv target)" || return 1
    _domain_config_validate_role_transition "$_dc_domain" "$_dc_role" || return 1
    case "$_dc_role" in
    alias | dedicated)
      target_role="$(domain_config_get "$_dc_root/$_dc_target/config" domain.csv role)" || return 1
      [ "$target_role" = backend ] || { _domain_csv_error "$_dc_config/domain.csv" 0 'target must be a configured primary backend'; return 1; }
      # Host associations remain valid when the last HTTP listener is removed.
      # Rendering resumes when a listener returns; explicit paths still must
      # reference an existing HTTP/HTTPS mapping below.
      ;;
    esac
    _domain_csv_read "$_dc_config/security_rules.csv" _domain_config_validate_global_order || return 1
    _domain_csv_read "$_dc_config/acl.csv" _domain_config_validate_global_order || return 1
    _domain_csv_read "$_dc_config/ports.csv" _domain_config_validate_port_refs || return 1
    _domain_csv_read "$_dc_config/paths.csv" _domain_config_validate_path_refs || return 1
  done
}

function _domain_config_validate_compiled() {
  _validate_backend_ports_state_for_render || return 1
  validate_backend_aliases_state_for_render || return 1
  nginx_directives_validate_for_render || return 1
  validate_tls_settings_for_render || return 1
  # These builders are confined to the temporary compiled model. They exercise
  # effective ACL/header/security inheritance before any live state changes.
  mkdir -p "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" || return 1
  _build_header_files || return 1
  build_security_rules_inc || return 1
}

function _domain_config_validate_compiled_config() (
  _domain_config_bind_config "$1" || exit 1
  # The source graph already validated certificate references. Validation
  # must also accept certificates that apply has not provisioned yet.
  function cert_ref_to_container_dir() {
    local output_name="${1:-}" reference="${2:-}"
    require_valid_var_name "$output_name" || return 1
    printf -v "$output_name" '/etc/letsencrypt/%s' "$reference"
  }
  _with_validated_render_settings _domain_config_validate_compiled
)

function domain_config_validate_tree() {
  local root="${1:-}" work="" result=0
  _domain_config_workspace work || return 1
  if ! domain_config_compile "$root" "$work/config"; then
    _domain_config_workspace_remove "$work" || true
    return 1
  fi
  _domain_config_validate_compiled_config "$work/config" || result=$?
  _domain_config_workspace_remove "$work" || return 1
  return "$result"
}
