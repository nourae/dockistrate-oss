#!/usr/bin/env bash

get_mode() {
  local target="$1" mode
  if mode=$(stat -c '%a' "$target" 2>/dev/null); then
    printf '%s' "$mode"
    return 0
  fi
  stat -f '%Lp' "$target"
}
