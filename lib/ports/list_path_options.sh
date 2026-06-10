# shellcheck shell=bash

function list_path_options() {
  local domain_filter="${1:-}" port_filter="${2:-}"
  if [ $# -gt 2 ]; then
    echo "[Usage] list-path-options [domain] [nginx_port]"
    exit 1
  fi

  if [ -n "$domain_filter" ]; then
    require_valid_domain "$domain_filter"
    domain_filter="$(primary_domain_for "$domain_filter")"
  fi
  if [ -n "$port_filter" ]; then
    require_valid_port "$port_filter"
  fi

  if [ ! -f "$BACKEND_PORTS_FILE" ] || ! grep -q '^path,' "$BACKEND_PORTS_FILE"; then
    echo "[Info] No path overrides configured."
    return
  fi

  local n=1
  local line="" line_no=0
  local type="" domain="" path="" header="" port="" ws="" redirect="" code="" match="" priority="" target="" rewrite="" reason="" loc=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    type="${STATE_BP_RECORD_TYPE:-}"
    domain="${STATE_BP_DOMAIN:-}"
    path="${STATE_BP_PATH_PREFIX:-}"
    header="${STATE_BP_HEADER_SET:-}"
    port="${STATE_BP_LISTEN_PORT:-}"
    ws="${STATE_BP_WS:-}"
    redirect="${STATE_BP_REDIRECT_FLAG:-}"
    code="${STATE_BP_REDIRECT_CODE:-}"
    match="${STATE_BP_PATH_MATCH:-prefix}"
    priority="${STATE_BP_PATH_PRIORITY:-100}"
    target="${STATE_BP_PATH_TARGET:-}"
    rewrite="${STATE_BP_PATH_REWRITE:-none}"
    reason="${STATE_BP_REASON:--}"
    loc="${STATE_BP_LOC:-auto}"
    [ "$type" = "path" ] || continue
    if [ -n "$domain_filter" ] && [ "$domain" != "$domain_filter" ]; then
      continue
    fi
    if [ -n "$port_filter" ] && [ "$port" != "$port_filter" ]; then
      continue
    fi
    local ws_disp redirect_disp header_disp
    ws_disp="$ws"
    [ -n "$ws_disp" ] || ws_disp="inherit"
    case "$redirect" in
    on) redirect_disp="on(${code:-301})" ;;
    off) redirect_disp="off" ;;
    inherit | "") redirect_disp="inherit" ;;
    *) redirect_disp="$redirect" ;;
    esac
    header_disp="$header"
    [ -n "$header_disp" ] || header_disp="-"
    [ -n "$target" ] || target="-"
    printf '%d: %s %s %s ws=%s redirect=%s headers=%s match=%s priority=%s target=%s rewrite=%s reason=%s loc=%s\n' \
      "$n" "$domain" "$port" "$path" "$ws_disp" "$redirect_disp" "$header_disp" "$match" "$priority" "$target" "$rewrite" "$reason" "$loc"
    n=$((n + 1))
  done <"$BACKEND_PORTS_FILE"
}

# Unified: TCP port mappings attached to a backend (keyed by domain)
# Adds an Nginx stream listen <listen_port> that proxies to the backend's
# container IP on <container_port>.
