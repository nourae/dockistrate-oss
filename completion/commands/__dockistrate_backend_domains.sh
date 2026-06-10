#!/usr/bin/env bash

__dockistrate_backend_domains() {
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    awk -F',' '$1=="backend" {print $2}' "$BACKEND_PORTS_FILE" | sort -u
  fi
}
