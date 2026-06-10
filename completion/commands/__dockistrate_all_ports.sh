#!/usr/bin/env bash

__dockistrate_all_ports() {
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    awk -F',' '$1=="port" {print $7}' "$BACKEND_PORTS_FILE" | sort -u
  fi
}
