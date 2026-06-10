# shellcheck shell=bash

function list_port_mappings() {
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Info] No port mappings configured."
    return
  fi
  if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    return 1
  fi
  local line="" line_no=0 found="false"
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      echo "[Error] Invalid backend_ports.csv row at line ${line_no}." >&2
      return 1
    fi
    if [ "$STATE_BP_RECORD_TYPE" = "port" ]; then
      found="true"
      break
    fi
  done <"$BACKEND_PORTS_FILE"
  if [ "$found" != "true" ]; then
    echo "[Info] No port mappings configured."
    return
  fi
  local n=1
  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      echo "[Error] Invalid backend_ports.csv row at line ${line_no}." >&2
      return 1
    fi
    [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
    if [ "$STATE_BP_PROTOCOL" = "tcp" ] || [ "$STATE_BP_PROTOCOL" = "udp" ]; then
      local proto_upper
      proto_upper="$(printf '%s' "$STATE_BP_PROTOCOL" | tr '[:lower:]' '[:upper:]')"
      printf '%d: [%s] %s %s -> %s\n' "$n" "$proto_upper" "$STATE_BP_DOMAIN" "$STATE_BP_LISTEN_PORT" "$STATE_BP_UPSTREAM_PORT"
    else
      local rdisp="${STATE_BP_REDIRECT_FLAG:-off}"
      if [ "$rdisp" = "on" ] && [ -n "$STATE_BP_REDIRECT_CODE" ]; then rdisp="on(${STATE_BP_REDIRECT_CODE})"; fi
      local http3_disp="-"
      local alt_svc_disp="-"
      if [ "$STATE_BP_PROTOCOL" = "https" ]; then
        http3_disp="${STATE_BP_HTTP3:-off}"
        alt_svc_disp="${STATE_BP_ALT_SVC:-auto}"
      fi
      printf '%d: %s %s -> %s proto=%s ws=%s cert=%s redirect=%s http3=%s alt-svc=%s\n' \
        "$n" "$STATE_BP_DOMAIN" "$STATE_BP_LISTEN_PORT" "$STATE_BP_UPSTREAM_PORT" "$STATE_BP_PROTOCOL" "$STATE_BP_WS" "$STATE_BP_CERT_REF" "$rdisp" "$http3_disp" "$alt_svc_disp"
    fi
    n=$((n + 1))
  done <"$BACKEND_PORTS_FILE"
}
