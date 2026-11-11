# shellcheck shell=bash

function _domain_config_render_complete() {
  domain_config_active || return 0
  local marker="$NGINX_CONFIG_DIR/domain_layout_version" temporary=""
  runtime_state_path_guard_if_declared "$marker" "generated domain layout marker" || return 1
  make_temp_for_file temporary "$marker" || return 1
  printf '2\n' >"$temporary" || { rm -f "$temporary"; return 1; }
  finalize_temp_file_with_mode "$marker" "$temporary" 600
}

function _domain_config_generated_ready() {
  local candidate="${1:-}" marker="$NGINX_CONFIG_DIR/domain_layout_version" root="" path="" file="" domain=""
  # Migration preserves the mounted legacy configuration. Merely publishing
  # diagnostic placeholders after another command does not render this layout.
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ "$(cat "$marker")" = 2 ] || return 1
  root="$(domain_config_root)" || return 1
  for path in "$NGINX_HTTP_CONF_DIR/domains" "$NGINX_STREAM_CONF_DIR/domains"; do
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
  done
  for path in "$candidate"/*; do
    [ -d "$path/config" ] || continue
    domain="${path##*/}"
    for file in nginx/http.conf nginx/stream.conf effective_settings.csv effective_listeners.csv; do
      [ -f "$root/$domain/generated/$file" ] && [ ! -L "$root/$domain/generated/$file" ] || return 1
    done
  done
}

function _domain_config_render_begin() {
  domain_config_active || return 0
  local directory="" file=""
  for directory in "$NGINX_HTTP_CONF_DIR/domains" "$NGINX_STREAM_CONF_DIR/domains"; do
    runtime_state_path_guard_if_declared "$directory" "generated domain fragments" || return 1
    mkdir -p "$directory" || return 1
    for file in "$directory"/*.conf; do
      [ -e "$file" ] || continue
      runtime_state_path_guard_if_declared "$file" "generated domain fragment" || return 1
      [ -f "$file" ] && [ ! -L "$file" ] || return 1
      rm -f "$file" || return 1
    done
  done
}

function _domain_config_emit_http() {
  local emitter="$1" aggregate="$2" identity="" fragment="" temporary=""
  shift 2
  case "$emitter" in
  _emit_backend_server_block_impl) identity="${4:-$1}" ;;
  _emit_dedicated_host_server_block_impl) identity="$1" ;;
  *) return 1 ;;
  esac
  _domain_config_validate_name "$identity" || return 1
  fragment="$NGINX_HTTP_CONF_DIR/domains/$identity.conf"
  runtime_state_path_guard_if_declared "$fragment" "generated domain fragment" || return 1
  mkdir -p "${fragment%/*}" || return 1
  make_temp_for_file temporary "$fragment" || return 1
  if ! "$emitter" "$temporary" "$@" || ! cat "$temporary" >>"$fragment" || ! cat "$temporary" >>"$aggregate"; then
    rm -f "$temporary"; return 1
  fi
  rm -f "$temporary"
}

function _domain_config_capture_stream() {
  local domain="$1" aggregate="$2" first_line="$3" fragment=""
  domain_config_active || return 0
  _domain_config_validate_name "$domain" || return 1
  fragment="$NGINX_STREAM_CONF_DIR/domains/$domain.conf"
  runtime_state_path_guard_if_declared "$fragment" "generated stream fragment" || return 1
  mkdir -p "${fragment%/*}" || return 1
  sed -n "${first_line},\$p" "$aggregate" >>"$fragment"
}

function _domain_config_publish_generated() {
  domain_config_active || return 0
  local root="" domain="" target="" source="" name="" parent="" applied="" value="" key=""
  root="$(domain_config_root)"
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    target="$root/$domain/generated"
    runtime_state_path_guard_if_declared "$target" "domain generated output" || return 1
    (umask 077; mkdir -p "$target/nginx") || return 1
    applied="$root/$domain/runtime/applied"
    parent="$(domain_config_get "$applied" domain.csv target)" || return 1
    for name in http stream; do
      if [ "$name" = http ]; then source="$NGINX_HTTP_CONF_DIR/domains/$domain.conf"; else source="$NGINX_STREAM_CONF_DIR/domains/$domain.conf"; fi
      if [ "$name" = http ] && [ ! -f "$source" ] && [ -n "$parent" ]; then source="$NGINX_HTTP_CONF_DIR/domains/$parent.conf"; fi
      if [ -f "$source" ]; then
        cp "$source" "$target/nginx/$name.conf" || return 1
      else
        printf '# No generated %s server for %s.\n' "$name" "$domain" >"$target/nginx/$name.conf" || return 1
      fi
    done
    for name in "$SECURITY_IP_DIR/$domain.inc" "$SECURITY_IP_STREAM_DIR/$domain.inc"; do
      if [ "$name" = "$SECURITY_IP_DIR/$domain.inc" ]; then source=acl-http.inc; else source=acl-stream.inc; fi
      runtime_state_path_guard_if_declared "$target/nginx/$source" "domain ACL output" || return 1
      if [ -f "$name" ]; then
        cp "$name" "$target/nginx/$source" || return 1
      elif [ -e "$target/nginx/$source" ]; then
        safe_rm_f "$target/nginx/$source" "$target/nginx" || return 1
      fi
    done
    _domain_config_effective_settings_record "$domain" >"$target/effective_settings.csv" || return 1
    source="$applied/ports.csv"
    [ -z "$parent" ] || source="$root/$parent/runtime/applied/ports.csv"
    printf 'listen_port,protocol,tls_protocols,tls_protocols_source,tls_ciphers,tls_ciphers_source\n' >"$target/effective_listeners.csv" || return 1
    _domain_csv_read "$source" _domain_config_effective_listener >>"$target/effective_listeners.csv" || return 1
  done < <(domain_config_list applied)
}

function _domain_config_effective_settings_record() {
  local domain="$1" key="" pair="" variable="" _dc_effective_value="" _dc_effective_source=""
  local -a headers=() values=()
  for key in http_version client_ip_header proxy_ip_header acl_policy acl_status security_rule_status; do
    _domain_config_effective_setting "$domain" "$key" || return 1
    headers+=("$key" "${key}_source")
    values+=("$_dc_effective_value" "$_dc_effective_source")
  done
  for pair in tls_protocols:TLS_PROTOCOLS tls_ciphers:TLS_CIPHERS trusted_proxy_ranges:TRUSTED_PROXY_RANGES \
    real_ip_recursive:REAL_IP_RECURSIVE nginx_image:NGINX_IMAGE certbot_image:CERTBOT_IMAGE; do
    key="${pair%%:*}"; variable="${pair#*:}"
    headers+=("$key" "${key}_source")
    values+=("${!variable}" global)
  done
  headers+=(shared_configuration shared_configuration_source)
  values+=("$CONFIG_DIR" global)
  csv_join_row "${headers[@]}" && csv_join_row "${values[@]}"
}

function _domain_config_effective_listener() {
  shift 2
  local port="$1" protocol="$3" setting="" value="" source="" custom=""
  local -a values=("$port" "$protocol")
  [ "$protocol" = https ] || return 0
  for setting in protocols ciphers; do
    source=global
    if [ "$setting" = protocols ]; then
      value="$(get_port_tls_protocols "$port")" || return 1
      custom="$(state_csv_get_two_col_value "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" "$port" '')" || return 1
    else
      value="$(get_port_tls_ciphers "$port")" || return 1
      custom="$(state_csv_get_two_col_value "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" "$port" '')" || return 1
    fi
    [ -z "$custom" ] || source="listener:$port"
    values+=("$value" "$source")
  done
  csv_join_row "${values[@]}"
}

function _domain_config_effective_setting() {
  local domain="$1" key="$2" root="" applied="" parent="" role="" identity="$1" source=global value="" inheritance=yes feature=""
  root="$(domain_config_root)"; applied="$root/$domain/runtime/applied"
  parent="$(domain_config_get "$applied" domain.csv target)" || return 1
  role="$(domain_config_get "$applied" domain.csv role)" || return 1
  case "$key" in
  http_version | client_ip_header | proxy_ip_header)
    # Ordinary aliases share their parent's HTTP server settings.
    [ "$role" != alias ] || identity="$parent"
    case "$key" in
    http_version) value="$(get_backend_http_version "$identity")" || return 1; inheritance=no ;;
    client_ip_header) value="$(get_backend_client_ip_header "$identity")" || return 1; feature=headers ;;
    proxy_ip_header) value="$(get_backend_proxy_ip_header "$identity")" || return 1; feature=headers ;;
    esac
    ;;
  acl_policy) value="$(get_backend_acl_policy "$domain")" || return 1; feature=acl ;;
  acl_status) value="$(get_backend_acl_status "$domain")" || return 1; feature=acl ;;
  security_rule_status) value="$(get_backend_security_rule_status "$domain")" || return 1; feature=security_rules ;;
  esac
  if _domain_config_has_row "$root/$identity/runtime/applied/settings.csv" 0 "$key"; then
    source="$identity"
  elif [ -n "$parent" ] && [ "$inheritance" = yes ]; then
    if [ "$role" = dedicated ]; then inheritance="$(get_dedicated_host_inheritance "$domain" "$feature")" || return 1; fi
    if [ "$inheritance" = yes ] && _domain_config_has_row "$root/$parent/runtime/applied/settings.csv" 0 "$key"; then source="$parent"; fi
  fi
  _dc_effective_value="$value"
  _dc_effective_source="$source"
}
