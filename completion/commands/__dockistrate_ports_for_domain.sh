#!/usr/bin/env bash

__dockistrate_ports_for_domain() {
  local domain="$1"
  if [ -n "$domain" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
    awk -F',' -v d="$domain" '$1=="port" && $2==d {print $7}' "$BACKEND_PORTS_FILE" | sort -u
  fi
}
