# shellcheck shell=bash

function _write_location_block() {
  local file="$1" path="$2" upstream="$3" ws="$4" domain="$5" pip_line="$6" cip_line="$7" header_line="$8" redirect_flag="$9" redirect_code="${10}" http_version="${11}" match_mode="${12:-prefix}" target_override="${13:-}" rewrite_behavior="${14:-none}" reason="${15:--}" loc="${16:-auto}" listen_port="${17:-}" directive_fallback_domain="${18:-}"

  if declare -F is_valid_path_prefix >/dev/null 2>&1; then
    if ! is_valid_path_prefix "$path"; then
      echo "[Error] Refusing to render unsafe path prefix '${path}' for domain '${domain}'." >&2
      return 1
    fi
  fi

  local location_token="$path"
  case "$match_mode" in
  exact)
    location_token="= ${path}"
    ;;
  regex)
    location_token="~* ${path}"
    ;;
  prefix | *)
    location_token="$path"
    ;;
  esac

  local effective_upstream="$upstream"
  if [ -n "$target_override" ]; then
    if is_valid_port "$target_override"; then
      if [[ "$upstream" == *:* ]]; then
        effective_upstream="${upstream%:*}:${target_override}"
      fi
    elif is_valid_path_target "$target_override"; then
      effective_upstream="$target_override"
    fi
  fi

  local escaped_reason="$reason" escaped_loc="$loc"
  if declare -F _escape_nginx_value >/dev/null 2>&1; then
    escaped_reason="$(_escape_nginx_value "$escaped_reason")"
    escaped_loc="$(_escape_nginx_value "$escaped_loc")"
  fi

  if [ "$redirect_flag" = "on" ]; then
    local code target_port="" target_part
    code="${redirect_code:-301}"
    if [[ "$code" == *:* ]]; then
      target_part="${code#*:}"
      code="${code%%:*}"
      if [ -n "$target_part" ]; then
        target_port="$target_part"
      fi
    fi
    {
      printf '    location %s {\n' "$location_token"
      if [ -n "$target_port" ]; then
        printf '        return %s https://$host:%s$request_uri;\n' "$code" "$target_port"
      else
        printf '        return %s https://$host$request_uri;\n' "$code"
      fi
      printf '    }\n'
    } >>"$file"
    return
  fi

  local effective_ws="$ws"
  [ -n "$effective_ws" ] || effective_ws="no"
  local httpv
  if [ "$effective_ws" = "yes" ]; then
    httpv="1.1"
  else
    httpv="${http_version:-$(get_proxy_http_version "$domain")}"
  fi

  {
    printf '    location %s {\n' "$location_token"
    printf '        include %s/security_rules.inc;\n' "$NGINX_CONTAINER_HTTP_CONF_DIR"
    printf '        set $dockistrate_path_reason "%s";\n' "$escaped_reason"
    printf '        set $dockistrate_path_loc "%s";\n' "$escaped_loc"
    if [ "$rewrite_behavior" = "strip-prefix" ] && [ "$path" != "/" ]; then
      local strip_prefix_pattern="$path"
      if [ "$match_mode" != "regex" ]; then
        strip_prefix_pattern="$(printf '%s' "$path" | sed -e 's/[][(){}.^$*+?|]/\\&/g')"
      fi
      printf '        rewrite ^%s/?(.*)$ /$1 break;\n' "$strip_prefix_pattern"
    elif [[ "$rewrite_behavior" == replace:* ]]; then
      local replacement
      replacement="${rewrite_behavior#replace:}"
      printf '        rewrite ^ %s break;\n' "$replacement"
    fi
    printf '        proxy_pass http://%s;\n' "$effective_upstream"
    printf '        proxy_http_version %s;\n' "$httpv"
    if [ "$effective_ws" = "yes" ]; then
      printf '        proxy_set_header Upgrade $http_upgrade;\n'
      printf '        proxy_set_header Connection "upgrade";\n'
    fi
    printf '        proxy_set_header Host $host;\n'
    [ -n "$pip_line" ] && printf '%s\n' "$pip_line"
    [ -n "$cip_line" ] && printf '%s\n' "$cip_line"
    printf '        include %s/backend_headers.conf;\n' "$NGINX_CONTAINER_HTTP_CONF_DIR"
    printf '        include %s/custom_headers.conf;\n' "$NGINX_CONTAINER_HTTP_CONF_DIR"
    [ -n "$header_line" ] && printf '%s\n' "$header_line"
    if [ -n "$listen_port" ] && declare -F nginx_directives_render_path_directives >/dev/null 2>&1; then
      if ! nginx_directives_render_path_directives "$file" "$domain" "$listen_port" "$path" "$directive_fallback_domain"; then
        return 1
      fi
    fi
    printf '    }\n'
  } >>"$file"
}
