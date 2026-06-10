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

  if container_exists "$cname"; then
    docker restart "$cname"
    echo "[Info] Restarted container '$cname'."
    log_msg "Restarted backend container $cname."
    create_backup "" "RestartBackend_${domain}"
  else
    echo "[Error] Container '$cname' not found." >&2
  fi
}
