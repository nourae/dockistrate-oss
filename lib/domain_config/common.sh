# shellcheck shell=bash

function domain_config_root() {
  printf '%s/domains\n' "${STATE_DIR:-${DOMAIN_CONFIG_MODULE_DIR%/lib/domain_config}/state}"
}

function domain_config_active() {
  local marker="${CONFIG_DIR:-${STATE_DIR:-${DOMAIN_CONFIG_MODULE_DIR%/lib/domain_config}/state}/config}/state_schema_version" value="" extra=""
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  {
    IFS= read -r value || [ -n "$value" ] || return 1
    if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
  } <"$marker"
  value="${value%$'\r'}"
  while [ "${value#0}" != "$value" ]; do value="${value#0}"; done
  [ "$value" = 5 ] || { [ "${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" = true ] && { [ "$value" = 2 ] || [ "$value" = 3 ] || [ "$value" = 4 ]; }; }
}

# Completion loads only declarations, so the application's validators may not
# exist yet. Keep discovery strict without sourcing runtime configuration.
function _domain_config_discovery_name_valid() {
  local name="${1:-}"
  if declare -F is_valid_domain >/dev/null 2>&1 && declare -F normalize_domain >/dev/null 2>&1; then
    is_valid_domain "$name" && [ "$name" = "$(normalize_domain "$name")" ]
  else
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
  fi
}

function domain_config_list() {
  local mode="${1:-all}" root="" path="" domain="" inventory="" line_no=0
  root="$(domain_config_root)" || return 1
  [ ! -L "$root" ] || return 1
  inventory="${CONFIG_DIR:-${root%/domains}/config}/domain_inventory.csv"
  {
  if [ "$mode" != draft ] && [ -f "$inventory" ] && [ ! -L "$inventory" ]; then
    while IFS= read -r domain || [ -n "$domain" ]; do
      line_no=$((line_no + 1)); [ "$line_no" -gt 1 ] || continue
      _domain_config_discovery_name_valid "$domain" || continue
      printf '%s\n' "$domain"
    done <"$inventory"
  fi
  for path in "$root"/*; do
    [ -d "$path" ] && [ ! -L "$path" ] || continue
    domain="${path##*/}"
    _domain_config_discovery_name_valid "$domain" || continue
    case "$mode" in
    applied) [ -f "$path/runtime/applied/domain.csv" ] || continue ;;
    draft) [ -e "$path/config" ] || [ -L "$path/config" ] || continue ;;
    all) [ -e "$path/config" ] || [ -L "$path/config" ] || [ -f "$path/runtime/applied/domain.csv" ] || continue ;;
    *) return 2 ;;
    esac
    printf '%s\n' "$domain"
  done
  } | LC_ALL=C sort -u
}

function _domain_config_write_inventory() {
  local tree="${1:-}" path="" domain="" temporary=""
  make_temp_for_file temporary "$CONFIG_DIR/domain_inventory.csv" || return 1
  printf 'domain\n' >"$temporary" || { rm -f "$temporary"; return 1; }
  for path in "$tree"/*; do
    [ -f "$path/config/domain.csv" ] || continue
    domain="${path##*/}"; _domain_config_validate_name "$domain" || { rm -f "$temporary"; return 1; }
    printf '%s\n' "$domain" >>"$temporary" || { rm -f "$temporary"; return 1; }
  done
  finalize_temp_file_with_mode "$CONFIG_DIR/domain_inventory.csv" "$temporary" 600
}

function _domain_config_error() {
  printf '[Error] %s\n' "$*" >&2
  return 1
}

function _domain_config_prepare() {
  if declare -F _dockistrate_source_deferred_modules >/dev/null 2>&1; then
    _dockistrate_source_deferred_modules || return 1
  fi
  if [ -s "${GLOBAL_SETTINGS_FILE:-}" ]; then
    load_config || return 1
  fi
  runtime_state_path_guard_if_declared "$(domain_config_root)" "domain configuration root"
}

function _domain_config_validate_name() {
  local name="${1:-}"
  require_valid_domain "$name" return || return 1
  [ "$name" = "$(normalize_domain "$name")" ] || return 1
}

function _domain_config_dir_guard() {
  local dir="${1:-}" file=""
  runtime_state_path_guard_if_declared "$dir" "domain configuration" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for file in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || {
      _domain_config_error "Expected a regular configuration file: $file"; return 1;
    }
  done
}

function _domain_config_copy_inputs() {
  local source="${1:-}" destination="${2:-}" file=""
  _domain_config_dir_guard "$source" || return 1
  runtime_state_path_guard_if_declared "$destination" "domain snapshot" || return 1
  (umask 077; mkdir -p "$destination") || return 1
  for file in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [ -f "$file" ] || continue
    cp -p "$file" "$destination/${file##*/}" || return 1
  done
}

function _domain_config_input_fingerprint() {
  local dir="${1:-}" file=""
  [ -d "$dir" ] || { printf 'missing\n'; return 0; }
  _domain_config_dir_guard "$dir" || return 1
  for file in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -f "$file" ] || continue
    printf '%s\n' "${file##*/}"
    cksum <"$file" || return 1
  done
}

function _domain_config_same() {
  local left="${1:-}" right="${2:-}" a="" b=""
  [ -d "$left" ] && [ -d "$right" ] || return 1
  a="$(domain_config_canonicalize "$left")" || return 1
  b="$(domain_config_canonicalize "$right")" || return 1
  [ "$a" = "$b" ]
}

function _domain_config_workspace() {
  local output_var="${1:-}" _domain_workspace_created=""
  require_valid_var_name "$output_var" || return 1
  # Read-only validation uses the OS temporary directory, not live state.
  _domain_workspace_created="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/dockistrate-domain.XXXXXXXX")" || return 1
  printf -v "$output_var" '%s' "$_domain_workspace_created"
}

function _domain_config_workspace_remove() {
  local work="${1:-}"
  case "$work" in "${TMPDIR:-/tmp}"/dockistrate-domain.*)
    [ -d "$work" ] && [ ! -L "$work" ] && rm -rf -- "$work"
    ;;
  *) return 1 ;;
  esac
}

function _domain_config_cache_files() {
  printf '%s\n' backend_ports.csv backend_aliases.csv dedicated_host_inheritance.csv \
    backend_headers.csv backend_http_versions.csv backend_client_ip_headers.csv \
    backend_proxy_ip_headers.csv backend_docker_opts.csv backend_acl_policies.csv \
    backend_acl_statuses.csv backend_security_rule_statuses.csv backend_mtls.csv \
    nginx_directives.csv security_rules.csv security_ip_rules.csv
}

function _domain_config_publish_cache() {
  local source="${1:-}" name="" tmp=""
  while IFS= read -r name; do
    [ -f "$source/$name" ] || return 1
    runtime_state_path_guard_if_declared "$CONFIG_DIR/$name" "derived configuration" || return 1
    if [ -f "$CONFIG_DIR/$name" ] && cmp -s "$source/$name" "$CONFIG_DIR/$name"; then continue; fi
    make_temp_for_file tmp "$CONFIG_DIR/$name" || return 1
    if ! cat "$source/$name" >"$tmp" || ! finalize_temp_file_with_mode "$CONFIG_DIR/$name" "$tmp" 600; then
      rm -f "$tmp"; return 1
    fi
  done < <(_domain_config_cache_files)
}

# Use in a subshell when validating a staged model. No paths outside config
# are rebound: certificates and immutable backend ownership retain their roots.
function _domain_config_bind_config() {
  CONFIG_DIR="${1:?config directory required}"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  STATE_SCHEMA_VERSION_FILE="$CONFIG_DIR/state_schema_version"
  BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
  BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
  BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
  BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
  BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
  BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
  BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
  BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
  BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
  BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
  BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
  NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
  SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
  SECURITY_RULES_DB="$SECURITY_RULES_FILE"
  SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
  SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
  CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
  PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
  PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
  ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
  NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
  NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
  NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
  NGINX_DIRECTIVES_GLOBAL_INCLUDE_FILE="$NGINX_HTTP_CONF_DIR/nginx_directives_global.inc"
  NGINX_DIRECTIVES_STREAM_GLOBAL_INCLUDE_FILE="$NGINX_STREAM_CONF_DIR/nginx_directives_stream_global.inc"
  SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
  SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
  SECURITY_RULES_INC="$NGINX_HTTP_CONF_DIR/security_rules.inc"
  PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
}
