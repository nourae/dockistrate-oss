# shellcheck shell=bash

function list_nginx_directives() {
  local scope="" domain="" listen_port="" path_prefix="" selector=""
  local usage_msg="[Usage] list-nginx-directives [all|global|backend <domain>|port <domain> <listen_port>|path <domain> <listen_port> <path_prefix>|stream-global|stream-backend <domain>|stream-port <domain> <listen_port>]"
  local line="" line_no=0 shown=0

  if [ "$#" -gt 0 ]; then
    selector="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

    case "$selector" in
    all)
      if [ "$#" -ne 1 ]; then
        echo "$usage_msg"
        return 1
      fi
      ;;
    *)
      scope="$(nginx_directive_normalize_scope "$selector" 2>/dev/null || true)"
      if [ -z "$scope" ]; then
        echo "$usage_msg"
        return 1
      fi

      case "$scope" in
      "$NGINX_DIRECTIVE_SCOPE_GLOBAL" | "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL")
        if [ "$#" -ne 1 ]; then
          echo "$usage_msg"
          return 1
        fi
        ;;
      "$NGINX_DIRECTIVE_SCOPE_BACKEND" | "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND")
        if [ "$#" -ne 2 ]; then
          echo "$usage_msg"
          return 1
        fi
        domain="$2"
        ;;
      "$NGINX_DIRECTIVE_SCOPE_PORT" | "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT")
        if [ "$#" -ne 3 ]; then
          echo "$usage_msg"
          return 1
        fi
        domain="$2"
        listen_port="$3"
        ;;
      "$NGINX_DIRECTIVE_SCOPE_PATH")
        if [ "$#" -ne 4 ]; then
          echo "$usage_msg"
          return 1
        fi
        domain="$2"
        listen_port="$3"
        path_prefix="$4"
        ;;
      esac

      if ! nginx_directives_resolve_scope_target scope domain listen_port path_prefix "$scope" "$domain" "$listen_port" "$path_prefix" "cleanup"; then
        return 1
      fi
      ;;
    esac
  fi

  nginx_directives_ensure_state_file || return 1

  printf "%-14s | %-28s | %-10s | %-20s | %-7s | %-28s | %s\n" "Scope" "Domain" "Port" "Path" "Mode" "Directive" "Value"
  echo "-----------------------------------------------------------------------------------------------------------------------------------------------------------"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_NGINX_DIRECTIVES_COLS" ] || continue

    if [ -n "$scope" ] && [ "${CSV_FIELDS[0]}" != "$scope" ]; then
      continue
    fi
    if [ -n "$domain" ] && [ "${CSV_FIELDS[1]}" != "$domain" ]; then
      continue
    fi
    if [ -n "$listen_port" ] && [ "${CSV_FIELDS[2]}" != "$listen_port" ]; then
      continue
    fi
    if [ -n "$path_prefix" ] && [ "${CSV_FIELDS[3]}" != "$path_prefix" ]; then
      continue
    fi

    printf "%-14s | %-28s | %-10s | %-20s | %-7s | %-28s | %s\n" \
      "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]:--}" "${CSV_FIELDS[2]:--}" "${CSV_FIELDS[3]:--}" "${CSV_FIELDS[4]}" "${CSV_FIELDS[5]}" "${CSV_FIELDS[6]}"
    shown=$((shown + 1))
  done <"$NGINX_DIRECTIVES_FILE"

  if [ "$shown" -eq 0 ]; then
    echo "[None]"
  fi
}
