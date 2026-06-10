# shellcheck shell=bash

function __arg_choices_protocol() {
  local cmd="$1"
  case "$cmd" in
  add-backend | add-port | update-port)
    # Offer explicit choices to avoid manual input
    echo -e "http|HTTP\nhttps|HTTPS\ntcp|TCP\nudp|UDP"
    ;;
  *)
    echo -e "http\nhttps\ntcp\nudp"
    ;;
  esac
}

function __arg_choices_ws() {
  local cmd="$1"
  # Interactive yes/no for WebSocket flag
  case "$cmd" in
  add-path-option)
    echo -e "inherit\nyes\nno"
    ;;
  update-path-option)
    local dom="${CURRENT_ARGS[0]:-}" port="${CURRENT_ARGS[1]:-}" path="${CURRENT_ARGS[2]:-}" cur_ws=""
    if [ -n "$dom" ] && [ -n "$port" ] && [ -n "$path" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      local line="" line_no=0
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        state_backend_ports_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
        if [ "${STATE_BP_RECORD_TYPE:-}" = "path" ] &&
          [ "${STATE_BP_DOMAIN:-}" = "$dom" ] &&
          [ "${STATE_BP_LISTEN_PORT:-}" = "$port" ] &&
          [ "${STATE_BP_PATH_PREFIX:-}" = "$path" ]; then
          cur_ws="${STATE_BP_WS:-}"
          break
        fi
      done <"$BACKEND_PORTS_FILE"
      [ -n "$cur_ws" ] || cur_ws="inherit"
      echo "__DEFAULT__|Keep current: $cur_ws"
    else
      echo "__DEFAULT__|Keep current"
    fi
    echo -e "inherit\nyes\nno"
    ;;
  *)
    echo -e "yes\nno"
    ;;
  esac
}

function __arg_choices_listen() {
  local cmd="$1"
  # Suggest listen ports based on protocol and allow default/blank
  local proto="" cport=""
  if [ "$cmd" = "add-backend" ]; then
    proto="${CURRENT_ARGS[3]:-}"
    cport="${CURRENT_ARGS[2]:-}"
    echo "__DEFAULT__|Use default (auto)"
  fi
  case "$proto" in
  https) echo "443" ;;
  http) echo "80" ;;
  tcp | udp)
    if [[ -n "$cport" && "$cport" =~ ^[0-9]+$ ]]; then
      echo "$cport"
    fi
    ;;
  esac
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_version() {
  echo -e "http1.0\nhttp1.1\nhttp2"
}
