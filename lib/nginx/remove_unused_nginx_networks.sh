# shellcheck shell=bash

function remove_unused_nginx_networks() {
  if ! nginx_container_is_managed; then
    return 0
  fi
  local required_nets="$DEFAULT_NETWORK"$'\n'
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local nets=""
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
      [ -n "${STATE_BP_NETWORK:-}" ] || continue
      nets+="${STATE_BP_NETWORK}"$'\n'
    done <"$BACKEND_PORTS_FILE"
    nets="$(printf '%s' "$nets" | awk 'NF > 0' | sort -u)"
    for net in $nets; do
      [ -z "$net" ] && continue
      required_nets+="${net}"$'\n'
    done
  fi

  local current_nets
  current_nets="$(get_container_network_names "$NGINX_CONTAINER_NAME")"
  for net in $current_nets; do
    if ! printf '%s\n' "$required_nets" | grep -Fx -- "$net" >/dev/null; then
      docker network disconnect "$net" "$NGINX_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
  done
}

# Determine the HTTP version used for proxy_pass upstream connections.
# When the external protocol is HTTP/2, Nginx still communicates with
# upstreams using HTTP/1.1.

# Resolve the variable to forward for the client IP header. If the
# header name is "X-Forwarded-For" the standard chain variable is used
# so the connecting IP is appended automatically. For any other header
# name the value from the incoming request is forwarded as-is.
