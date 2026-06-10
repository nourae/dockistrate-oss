# shellcheck shell=bash

function show_server_tokens() {
  local current=""
  current="$(nginx_directives_state_get_exact_value "global" "" "" "server_tokens" "" 2>/dev/null || true)"
  if [ "$current" = "on" ]; then
    echo "on"
  else
    echo "off"
  fi
}
