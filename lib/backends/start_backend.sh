# shellcheck shell=bash
function start_backend() {
  local domain="${1:-}"
  [ -z "$domain" ] && {
    echo "[Usage] start-backend <domain>"
    exit 1
  }
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  local cname="backend-$(sanitize_domain_name "$domain")"

  if declare -F domain_config_runtime_enabled >/dev/null 2>&1 && domain_config_runtime_enabled; then
    domain_config_backend_set_state "$domain" running
    return $?
  fi

  _backend_container_snapshot "$domain" || return 1
  if ! docker start "$BACKEND_CONTAINER_ID"; then
    return 1
  fi
  echo "[Info] Started container '$cname'."
  log_msg "Started backend container $cname."
  create_backup "" "StartBackend_${domain}"
}
