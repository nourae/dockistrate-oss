# shellcheck shell=bash

_RPR_REWRITE_DOMAIN=""
_RPR_REWRITE_PORT=""

function _remove_port_redirect_rewrite_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
    [ "$STATE_BP_DOMAIN" = "${_RPR_REWRITE_DOMAIN:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_RPR_REWRITE_PORT:-}" ]; then
    CSV_FIELDS[11]="off"
    CSV_FIELDS[12]=""
  fi
  return 0
}

function remove_port_redirect() {
  local domain="${1:-}" port="${2:-}"
  if [ -z "$domain" ] || [ -z "$port" ]; then
    echo "[Usage] remove-port-redirect <domain> <port>"
    exit 1
  fi
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] No port mappings configured." >&2
    exit 1
  }
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_port_redirect_${domain}_${port}"; then
    exit 1
  fi
  _RPR_REWRITE_DOMAIN="$domain"
  _RPR_REWRITE_PORT="$port"
  if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _remove_port_redirect_rewrite_cb; then
    return 1
  fi
  echo "[Info] Redirect disabled for ${domain} on port ${port}."
  create_backup "" "RemovePortRedirect_${domain}_${port}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
