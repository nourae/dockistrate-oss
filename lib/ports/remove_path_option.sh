# shellcheck shell=bash

_RPO_DOMAIN=""
_RPO_PORT=""
_RPO_PATH_PREFIX=""

function _remove_path_option_rewrite_row_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "path" ] &&
    [ "$STATE_BP_DOMAIN" = "${_RPO_DOMAIN:-}" ] &&
    [ "$STATE_BP_PATH_PREFIX" = "${_RPO_PATH_PREFIX:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_RPO_PORT:-}" ]; then
    return 10
  fi
  return 0
}

function remove_path_option() {
  local domain="${1:-}" listen_port="${2:-}" path_prefix="${3:-}"
  if [ -z "$domain" ] || [ -z "$listen_port" ] || [ -z "$path_prefix" ]; then
    echo "[Usage] remove-path-option <domain> <nginx_port> <path_prefix>"
    exit 1
  fi

  ensure_valid_or_prompt domain "$domain" "domain" "" is_valid_domain
  ensure_valid_or_prompt listen_port "$listen_port" "nginx_port" "" is_valid_port
  ensure_valid_or_prompt path_prefix "$path_prefix" "path" "/" is_valid_path_prefix

  resolve_backend_domain domain "$domain" true

  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] No path overrides configured." >&2
    exit 1
  }
  local line="" line_no=0 found="false"
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      continue
    fi
    if [ "$STATE_BP_RECORD_TYPE" = "path" ] &&
      [ "$STATE_BP_DOMAIN" = "$domain" ] &&
      [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ] &&
      [ "$STATE_BP_PATH_PREFIX" = "$path_prefix" ]; then
      found="true"
      break
    fi
  done <"$BACKEND_PORTS_FILE"
  if [ "$found" != "true" ]; then
    echo "[Error] Path override for $domain on port $listen_port at '$path_prefix' not found." >&2
    exit 1
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_path_${domain}_${listen_port}_$(_sanitize_path_for_id "$path_prefix")"; then
    exit 1
  fi
  _RPO_DOMAIN="$domain"
  _RPO_PORT="$listen_port"
  _RPO_PATH_PREFIX="$path_prefix"
  if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _remove_path_option_rewrite_row_cb; then
    return 1
  fi
  local path_id
  path_id=$(_sanitize_path_for_id "$path_prefix")
  echo "[Info] Removed path override ${domain}:${listen_port}${path_prefix}."
  log_msg "Removed path override ${domain}:${listen_port}${path_prefix}"
  create_backup "" "RemovePath_${domain}_${listen_port}_${path_id}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
