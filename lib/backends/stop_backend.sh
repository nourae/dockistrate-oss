# shellcheck shell=bash
function stop_backend() {
  local domain="${1:-}"
  [ -z "$domain" ] && {
    echo "[Usage] stop-backend <domain>"
    exit 1
  }
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  local cname="backend-$(sanitize_domain_name "$domain")"

  if container_exists "$cname"; then
    docker stop "$cname"
    echo "[Info] Stopped container '$cname'."
    log_msg "Stopped backend container $cname."
    create_backup "" "StopBackend_${domain}"
  else
    echo "[Error] Container '$cname' not found." >&2
  fi
}
