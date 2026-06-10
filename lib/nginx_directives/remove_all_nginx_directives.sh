# shellcheck shell=bash

function _remove_all_nginx_directives_find_owned() {
  local scope_filter="${1:-}" domain_filter="${2:-}" port_filter="${3:-}" path_filter="${4:-}"
  local line="" line_no=0 directive=""

  [ -f "$NGINX_DIRECTIVES_FILE" ] || return 1
  nginx_directives_ensure_state_file || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_NGINX_DIRECTIVES_COLS" ] || continue

    if [ -n "$scope_filter" ] && [ "${CSV_FIELDS[0]}" != "$scope_filter" ]; then
      continue
    fi
    if [ -n "$domain_filter" ] && [ "${CSV_FIELDS[1]}" != "$domain_filter" ]; then
      continue
    fi
    if [ -n "$port_filter" ] && [ "${CSV_FIELDS[2]}" != "$port_filter" ]; then
      continue
    fi
    if [ -n "$path_filter" ] && [ "${CSV_FIELDS[3]}" != "$path_filter" ]; then
      continue
    fi

    directive="${CSV_FIELDS[5]}"
    if nginx_directive_is_owned "$directive"; then
      printf '%s\n' "$directive"
      return 0
    fi
  done <"$NGINX_DIRECTIVES_FILE"

  return 1
}

function remove_all_nginx_directives() {
  local scope="" domain="" listen_port="" path_prefix="" removed_count="0" selector=""
  local usage_msg="[Usage] remove-all-nginx-directives [all|global|backend <domain>|port <domain> <listen_port>|path <domain> <listen_port> <path_prefix>|stream-global|stream-backend <domain>|stream-port <domain> <listen_port>]"

  if [ "$#" -eq 0 ]; then
    scope=""
    domain=""
    listen_port=""
  else
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

  if nginx_directive_strict_is_on; then
    local owned_match owner
    owned_match="$(_remove_all_nginx_directives_find_owned "$scope" "$domain" "$listen_port" "$path_prefix" || true)"
    if [ -n "$owned_match" ]; then
      owner="$(nginx_directive_resolve_owner_guidance "$owned_match")"
      echo "[Error] Matching rows include owned directive '${owned_match}' (owner: ${owner}). Disable strict mode or use the owner command." >&2
      return 1
    fi
  fi

  begin_transaction "remove_all_nginx_directives" "$CONFIG_DIR"
  if ! removed_count="$(nginx_directives_state_remove_matching "$scope" "$domain" "$listen_port" "$path_prefix" "")"; then
    _rollback_handler
  fi
  if ! update_nginx_config; then
    _rollback_handler
  fi
  end_transaction_success

  echo "[Info] Removed ${removed_count} nginx directive row(s)."
}
