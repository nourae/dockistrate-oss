# shellcheck shell=bash

function _interactive_dashboard_backend_ports_count() {
  local wanted_type="${1:-}" backend_ports_file="${BACKEND_PORTS_FILE:-}" count=0 line="" line_no=0 record_type=""
  [ -n "$wanted_type" ] || {
    printf '%s\n' "0"
    return 0
  }
  [ -n "$backend_ports_file" ] || {
    printf '%s\n' "0"
    return 0
  }
  [ -f "$backend_ports_file" ] || {
    printf '%s\n' "0"
    return 0
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    record_type=""
    if declare -F state_backend_ports_parse_line >/dev/null 2>&1; then
      state_backend_ports_parse_line "$line" >/dev/null 2>&1 || continue
      [ "$CSV_FIELD_COUNT" -eq "${STATE_BACKEND_PORTS_COLS:-0}" ] || continue
      record_type="${STATE_BP_RECORD_TYPE:-}"
    else
      record_type="${line%%,*}"
    fi
    [ "$record_type" = "$wanted_type" ] && count=$((count + 1))
  done <"$backend_ports_file"

  printf '%s\n' "$count"
}

function interactive_dashboard_proxy_state() {
  local cname="${NGINX_CONTAINER_NAME:-nginx-proxy}" container_names="" status=""
  if [ "${DOCKISTRATE_RUNTIME_PREPARED:-false}" != true ]; then
    printf '%s\n' "unknown"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "unknown"
    return 0
  fi
  if ! container_names="$(docker ps -a --format '{{.Names}}' 2>/dev/null)"; then
    printf '%s\n' "unknown"
    return 0
  fi
  if ! printf '%s\n' "$container_names" | grep -Fxq "$cname"; then
    printf '%s\n' "unknown"
    return 0
  fi
  if ! status="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null)"; then
    printf '%s\n' "unknown"
    return 0
  fi
  case "$status" in
  running)
    printf '%s\n' "running"
    ;;
  created | restarting | paused | exited | dead | removing)
    printf '%s\n' "stopped"
    ;;
  *)
    printf '%s\n' "unknown"
    ;;
  esac
}

function interactive_dashboard_backend_count() {
  _interactive_dashboard_backend_ports_count "backend"
}

function interactive_dashboard_port_count() {
  _interactive_dashboard_backend_ports_count "port"
}

function interactive_dashboard_cert_count() {
  local certs_dir="${CERTS_DIR:-}" provider="" cert_dir="" count=0
  [ -n "$certs_dir" ] || {
    printf '%s\n' "0"
    return 0
  }
  for provider in letsencrypt selfsigned custom; do
    [ -d "${certs_dir}/${provider}/live" ] || continue
    for cert_dir in "${certs_dir}/${provider}/live"/*; do
      [ -d "$cert_dir" ] || continue
      count=$((count + 1))
    done
  done
  printf '%s\n' "$count"
}

function interactive_dashboard_backup_count() {
  local backups_dir="${BACKUP_DIR:-}" backup_item="" count=0
  [ -n "$backups_dir" ] || {
    printf '%s\n' "0"
    return 0
  }
  [ -d "$backups_dir" ] || {
    printf '%s\n' "0"
    return 0
  }

  for backup_item in "$backups_dir"/*; do
    [ -e "$backup_item" ] || continue
    if [ -d "$backup_item" ]; then
      count=$((count + 1))
      continue
    fi
    case "$(basename "$backup_item")" in
    *.tar.gz)
      count=$((count + 1))
      ;;
    esac
  done

  printf '%s\n' "$count"
}

function interactive_dashboard_capture_state() {
  local container_names=""
  if [ "${DOCKISTRATE_RUNTIME_PREPARED:-false}" != true ]; then
    printf '%s\n' "unknown"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "unknown"
    return 0
  fi
  if ! container_names="$(docker ps --format '{{.Names}}' 2>/dev/null)"; then
    printf '%s\n' "unknown"
    return 0
  fi
  if printf '%s\n' "$container_names" | grep -Fxq 'nginx-capture'; then
    printf '%s\n' "active"
  else
    printf '%s\n' "inactive"
  fi
}

function interactive_dashboard_summary() {
  local proxy_state="" backend_count="" port_count="" cert_count="" backup_count="" capture_state=""
  proxy_state="$(interactive_dashboard_proxy_state 2>/dev/null || printf '%s\n' "unknown")"
  backend_count="$(interactive_dashboard_backend_count 2>/dev/null || printf '%s\n' "0")"
  port_count="$(interactive_dashboard_port_count 2>/dev/null || printf '%s\n' "0")"
  cert_count="$(interactive_dashboard_cert_count 2>/dev/null || printf '%s\n' "0")"
  backup_count="$(interactive_dashboard_backup_count 2>/dev/null || printf '%s\n' "0")"
  capture_state="$(interactive_dashboard_capture_state 2>/dev/null || printf '%s\n' "unknown")"

  printf 'Proxy:        %s\n' "${proxy_state:-unknown}"
  printf 'Backends:     %s configured\n' "${backend_count:-0}"
  printf 'Ports:        %s mappings\n' "${port_count:-0}"
  printf 'Certificates: %s cert directories\n' "${cert_count:-0}"
  printf 'Backups:      %s available\n' "${backup_count:-0}"
  printf 'Capture:      %s\n' "${capture_state:-unknown}"
}
