#!/usr/bin/env bash

__dockistrate_nginx_directive_catalog_names_http() {
  cat <<'EOF_NAMES'
client_max_body_size
client_body_buffer_size
client_header_buffer_size
large_client_header_buffers
proxy_connect_timeout
proxy_read_timeout
proxy_send_timeout
send_timeout
proxy_buffering
proxy_request_buffering
proxy_buffer_size
proxy_buffers
proxy_busy_buffers_size
underscores_in_headers
ignore_invalid_headers
server_tokens
EOF_NAMES
}

__dockistrate_nginx_directive_catalog_names_stream() {
  cat <<'EOF_NAMES'
proxy_connect_timeout
proxy_timeout
proxy_protocol
proxy_socket_keepalive
proxy_buffer_size
proxy_download_rate
proxy_upload_rate
proxy_requests
proxy_responses
proxy_next_upstream
proxy_next_upstream_timeout
proxy_next_upstream_tries
preread_buffer_size
preread_timeout
tcp_nodelay
ssl_preread
EOF_NAMES
}

__dockistrate_nginx_directive_catalog_names_for_scope() {
  local scope="${1:-global}"
  case "$scope" in
  stream-global | stream-backend | stream-port)
    __dockistrate_nginx_directive_catalog_names_stream
    ;;
  *)
    __dockistrate_nginx_directive_catalog_names_http
    ;;
  esac
}

__dockistrate_nginx_directive_raw_names_for_scope() {
  local scope="${1:-global}"
  {
    __dockistrate_nginx_directive_catalog_names_for_scope "$scope"
    cat <<'EOF_NAMES'
ssl_protocols
ssl_ciphers
EOF_NAMES
  } | awk 'NF' | sort -u
}

__dockistrate_nginx_directive_domains_for_scope() {
  local scope="${1:-global}"

  if [[ "$scope" == stream-* ]]; then
    __dockistrate_backend_domains | awk 'NF' | sort -u
    return 0
  fi

  {
    __dockistrate_backend_domains
    if [ -f "$BACKEND_ALIASES_FILE" ]; then
      awk -F',' '$1=="dedicated" {print $2}' "$BACKEND_ALIASES_FILE"
    fi
  } | awk 'NF' | sort -u
}

__dockistrate_nginx_directive_ports_for_domain() {
  local domain="$1" protocol_filter="${2:-all}"
  if [ -n "$domain" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
    awk -F',' -v d="$domain" -v filter="$protocol_filter" '
      $1=="port" && $2==d {
        if (filter == "http-only" && ($9 == "tcp" || $9 == "udp")) next
        if (filter == "tcp-only" && ($9 != "tcp" && $9 != "udp")) next
        if (filter == "stream-only" && ($9 != "tcp" && $9 != "udp")) next
        print $7
      }
    ' "$BACKEND_PORTS_FILE" | sort -u
  fi
}

__dockistrate_nginx_directive_paths_for_domain_port() {
  local domain="$1" listen_port="$2"
  if [ -n "$domain" ] && [ -n "$listen_port" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
    awk -F',' -v d="$domain" -v p="$listen_port" '
      $1=="path" && $2==d && $7==p { print $5 }
    ' "$BACKEND_PORTS_FILE" | sort -u
  fi
}

_dockistrate_complete_nginx_directives() {
  local command="$1" scope="" domain="" directives="" domains="" ports=""
  local scope_values="global backend port path stream-global stream-backend stream-port"

  case "$command" in
  set-nginx-directive-strict)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "on off" -- "$cur"))
      return 0
    fi
    ;;
  set-nginx-directive)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "$scope_values" -- "$cur"))
      return 0
    fi

    scope="${words[2]:-}"
    directives="$(__dockistrate_nginx_directive_catalog_names_for_scope "$scope")"
    domains="$(__dockistrate_nginx_directive_domains_for_scope "$scope")"

    case "$scope" in
    global | stream-global)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    backend | stream-backend)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    path)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        domain="${words[3]:-}"
        ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "http-only")"
        COMPREPLY=($(compgen -W "$ports" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 5 ]]; then
        domain="${words[3]:-}"
        local path_port="${words[4]:-}"
        local paths
        paths="$(__dockistrate_nginx_directive_paths_for_domain_port "$domain" "$path_port")"
        COMPREPLY=($(compgen -W "$paths" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 6 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    port | stream-port)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        domain="${words[3]:-}"
        if [ "$scope" = "stream-port" ]; then
          ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "stream-only")"
        else
          ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "http-only")"
        fi
        COMPREPLY=($(compgen -W "$ports" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 5 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    esac
    ;;
  set-nginx-directive-raw | remove-nginx-directive)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "$scope_values" -- "$cur"))
      return 0
    fi

    scope="${words[2]:-}"
    directives="$(__dockistrate_nginx_directive_raw_names_for_scope "$scope")"
    domains="$(__dockistrate_nginx_directive_domains_for_scope "$scope")"

    case "$scope" in
    global | stream-global)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    backend | stream-backend)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    path)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        domain="${words[3]:-}"
        ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "http-only")"
        COMPREPLY=($(compgen -W "$ports" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 5 ]]; then
        domain="${words[3]:-}"
        local path_port="${words[4]:-}"
        local paths
        paths="$(__dockistrate_nginx_directive_paths_for_domain_port "$domain" "$path_port")"
        COMPREPLY=($(compgen -W "$paths" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 6 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    port | stream-port)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        domain="${words[3]:-}"
        if [ "$scope" = "stream-port" ]; then
          ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "stream-only")"
        else
          ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "http-only")"
        fi
        COMPREPLY=($(compgen -W "$ports" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 5 ]]; then
        COMPREPLY=($(compgen -W "$directives" -- "$cur"))
        return 0
      fi
      ;;
    esac
    ;;
  remove-all-nginx-directives | list-nginx-directives)
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=($(compgen -W "all $scope_values" -- "$cur"))
      return 0
    fi

    scope="${words[2]:-}"
    domains="$(__dockistrate_nginx_directive_domains_for_scope "$scope")"
    case "$scope" in
    backend | stream-backend)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      ;;
    path)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        domain="${words[3]:-}"
        ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "http-only")"
        COMPREPLY=($(compgen -W "$ports" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 5 ]]; then
        domain="${words[3]:-}"
        local path_port="${words[4]:-}"
        local paths
        paths="$(__dockistrate_nginx_directive_paths_for_domain_port "$domain" "$path_port")"
        COMPREPLY=($(compgen -W "$paths" -- "$cur"))
        return 0
      fi
      ;;
    port | stream-port)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
        return 0
      fi
      if [[ $cword -eq 4 ]]; then
        domain="${words[3]:-}"
        if [ "$scope" = "stream-port" ]; then
          ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "stream-only")"
        else
          ports="$(__dockistrate_nginx_directive_ports_for_domain "$domain" "http-only")"
        fi
        COMPREPLY=($(compgen -W "$ports" -- "$cur"))
        return 0
      fi
      ;;
    esac
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_nginx_directives)
