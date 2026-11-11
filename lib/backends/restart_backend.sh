# shellcheck shell=bash
function restart_backend() {
  local domain="${1:-}"
  [ -z "$domain" ] && {
    echo "[Usage] restart-backend <domain>"
    exit 1
  }
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  local cname="backend-$(sanitize_domain_name "$domain")"

  if declare -F domain_config_runtime_enabled >/dev/null 2>&1 && domain_config_runtime_enabled; then
    domain_config_backend_set_state "$domain" running restart
    return $?
  fi

  _backend_container_snapshot "$domain" || return 1
  if ! docker restart "$BACKEND_CONTAINER_ID"; then
    return 1
  fi
  echo "[Info] Restarted container '$cname'."
  log_msg "Restarted backend container $cname."
  create_backup "" "RestartBackend_${domain}"
}
