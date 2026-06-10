#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/tls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_update_backend_stop_before_replace.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha1"

INTERACTIVE=false

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$CERTS_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS

cat >"$BACKEND_HEADERS_FILE" <<'EOF_HEADERS'
domain,header_type,header_name,header_value
EOF_HEADERS

cat >"$BACKEND_HTTP_FILE" <<'EOF_HTTP'
domain,http_version
EOF_HTTP

cat >"$BACKEND_MTLS_FILE" <<'EOF_MTLS'
domain,mtls_directory
EOF_MTLS

cat >"$BACKEND_CLIENT_IP_HEADER_FILE" <<'EOF_CLIENT'
domain,client_ip_header_name
EOF_CLIENT

cat >"$BACKEND_PROXY_IP_HEADER_FILE" <<'EOF_PROXY'
domain,proxy_ip_header_name
EOF_PROXY

cat >"$BACKEND_ACL_POLICY_FILE" <<'EOF_ACL'
domain,acl_policy
EOF_ACL

cat >"$BACKEND_ACL_STATUS_FILE" <<'EOF_ACL_STATUS'
domain,acl_status_code
EOF_ACL_STATUS

cat >"$BACKEND_SECURITY_RULE_STATUS_FILE" <<'EOF_SEC_STATUS'
domain,security_rule_status_code
EOF_SEC_STATUS

cat >"$SECURITY_RULES_DB" <<'EOF_SEC_RULES'
enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location
EOF_SEC_RULES

cat >"$SECURITY_IP_RULES_DB" <<'EOF_SEC_IPS'
enabled,domain,scope,action,ip_value,status_code
EOF_SEC_IPS

cat >"$BACKEND_DOCKER_OPTS_FILE" <<'EOF_DOCKER_OPTS'
key,docker_options
backend:example.com,-p 18181:80 --label app=seed
EOF_DOCKER_OPTS

domain="example.com"
cname="backend-example.com"
test_backend_name="$cname"
original_container_id="original-container-id"
replacement_runtime_id="replacement-container-id"
docker_log_file="$TMP_ROOT/docker_update_backend_stop_before_replace.log"
output_file="$TMP_ROOT/update_backend_stop_before_replace.out"
active_meta_file="$TMP_ROOT/active.meta"
backup_meta_file="$TMP_ROOT/backup.meta"

function write_container_meta() {
  local file="${1:-}" exists="${2:-false}" name="${3:-}" status="${4:-}" id="${5:-}"
  {
    printf 'exists=%s\n' "$exists"
    printf 'name=%s\n' "$name"
    printf 'status=%s\n' "$status"
    printf 'id=%s\n' "$id"
  } >"$file"
}

function read_container_meta() {
  local file="${1:-}" key="${2:-}"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

write_container_meta "$active_meta_file" "true" "$test_backend_name" "running" "$original_container_id"
write_container_meta "$backup_meta_file" "false" "" "" ""

function container_exists() {
  local candidate="${1:-}"
  if [ "$candidate" = "$test_backend_name" ]; then
    [ "$(read_container_meta "$active_meta_file" exists || true)" = "true" ]
    return
  fi

  local backup_name backup_exists
  backup_name="$(read_container_meta "$backup_meta_file" name || true)"
  backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ]; then
    [ "$backup_exists" = "true" ]
    return
  fi

  return 1
}

function docker() {
  printf 'subcommand=%s %s\n' "$1" "$*" >>"$docker_log_file"
  case "${1:-}" in
  rename)
    local src="${2:-}" dest="${3:-}"
    local active_exists active_status active_id
    local backup_name backup_exists backup_status backup_id

    active_exists="$(read_container_meta "$active_meta_file" exists || true)"
    active_status="$(read_container_meta "$active_meta_file" status || true)"
    active_id="$(read_container_meta "$active_meta_file" id || true)"
    backup_name="$(read_container_meta "$backup_meta_file" name || true)"
    backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
    backup_status="$(read_container_meta "$backup_meta_file" status || true)"
    backup_id="$(read_container_meta "$backup_meta_file" id || true)"

    if [ "$src" = "$test_backend_name" ]; then
      [ "$active_exists" = "true" ] || return 1
      [ "$backup_exists" = "false" ] || return 1
      write_container_meta "$backup_meta_file" "true" "$dest" "$active_status" "$active_id"
      write_container_meta "$active_meta_file" "false" "$test_backend_name" "" ""
      return 0
    fi

    if [ -n "$backup_name" ] && [ "$src" = "$backup_name" ] && [ "$dest" = "$test_backend_name" ]; then
      [ "$backup_exists" = "true" ] || return 1
      [ "$active_exists" = "false" ] || return 1
      write_container_meta "$active_meta_file" "true" "$test_backend_name" "$backup_status" "$backup_id"
      write_container_meta "$backup_meta_file" "false" "$backup_name" "" ""
      return 0
    fi
    return 1
    ;;
  run)
    local current_backup_exists current_backup_status
    current_backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
    current_backup_status="$(read_container_meta "$backup_meta_file" status || true)"
    if [ "$current_backup_exists" = "true" ] && [ "$current_backup_status" = "running" ]; then
      return 1
    fi
    write_container_meta "$active_meta_file" "true" "$test_backend_name" "running" "$replacement_runtime_id"
    printf '%s\n' "$replacement_runtime_id"
    return 0
    ;;
  inspect)
    if [ "${2:-}" = "-f" ]; then
      local format="${3:-}" target="${4:-}"
      local active_exists active_status active_id
      local backup_name backup_exists backup_status backup_id

      active_exists="$(read_container_meta "$active_meta_file" exists || true)"
      active_status="$(read_container_meta "$active_meta_file" status || true)"
      active_id="$(read_container_meta "$active_meta_file" id || true)"
      backup_name="$(read_container_meta "$backup_meta_file" name || true)"
      backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
      backup_status="$(read_container_meta "$backup_meta_file" status || true)"
      backup_id="$(read_container_meta "$backup_meta_file" id || true)"

      case "$format" in
      *'.Config.Image'*)
        if [ "$target" = "$test_backend_name" ] && [ "$active_exists" = "true" ]; then
          printf '%s\n' 'nginx:alpine'
          return 0
        fi
        if [ -n "$backup_name" ] && [ "$target" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
          printf '%s\n' 'nginx:alpine'
          return 0
        fi
        return 1
        ;;
      *'.NetworkSettings.Networks'*)
        if [ "$target" = "$test_backend_name" ] && [ "$active_exists" = "true" ]; then
          printf '%s\n' '172.30.0.99'
          return 0
        fi
        return 1
        ;;
      *'.State.Status'*)
        if [ "$target" = "$test_backend_name" ] && [ "$active_exists" = "true" ]; then
          printf '%s\n' "$active_status"
          return 0
        fi
        if [ -n "$backup_name" ] && [ "$target" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
          printf '%s\n' "$backup_status"
          return 0
        fi
        return 1
        ;;
      *'.Id'*)
        if [ "$target" = "$test_backend_name" ] && [ "$active_exists" = "true" ]; then
          printf '%s\n' "$active_id"
          return 0
        fi
        if [ -n "$backup_name" ] && [ "$target" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
          printf '%s\n' "$backup_id"
          return 0
        fi
        return 1
        ;;
      esac
    fi
    return 1
    ;;
  stop)
    local target_stop="${2:-}"
    local backup_name backup_exists backup_id
    backup_name="$(read_container_meta "$backup_meta_file" name || true)"
    backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
    backup_id="$(read_container_meta "$backup_meta_file" id || true)"
    if [ -n "$backup_name" ] && [ "$target_stop" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
      write_container_meta "$backup_meta_file" "true" "$backup_name" "exited" "$backup_id"
      return 0
    fi
    return 1
    ;;
  start)
    local target_start="${2:-}"
    local active_exists active_id
    active_exists="$(read_container_meta "$active_meta_file" exists || true)"
    active_id="$(read_container_meta "$active_meta_file" id || true)"
    if [ "$target_start" = "$test_backend_name" ] && [ "$active_exists" = "true" ]; then
      write_container_meta "$active_meta_file" "true" "$test_backend_name" "running" "$active_id"
      return 0
    fi
    return 1
    ;;
  rm)
    local target="${@: -1}"
    local active_exists backup_name backup_exists
    active_exists="$(read_container_meta "$active_meta_file" exists || true)"
    backup_name="$(read_container_meta "$backup_meta_file" name || true)"
    backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
    if [ "$target" = "$test_backend_name" ] && [ "$active_exists" = "true" ]; then
      write_container_meta "$active_meta_file" "false" "$test_backend_name" "" ""
      return 0
    fi
    if [ -n "$backup_name" ] && [ "$target" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
      write_container_meta "$backup_meta_file" "false" "$backup_name" "" ""
      return 0
    fi
    return 1
    ;;
  network)
    return 0
    ;;
  esac
  return 0
}

function ensure_network_exists() { :; }
function update_nginx_config() { :; }
function create_backup() { :; }
function capture_docker_logs() { :; }
function log_msg() { :; }

set +e
update_backend "$domain" --image hashicorp/http-echo >"$output_file" 2>&1
status=$?
set -e
output="$(cat "$output_file")"

if [ "$status" -ne 0 ]; then
  echo "[Error] update_backend failed even though the staged container should have been stopped before replacement launch." >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

if ! printf '%s' "$output" | grep -Fq "Backend '${domain}' updated."; then
  echo "[Error] update_backend success output missing expected confirmation." >&2
  exit 1
fi

if [ "$(read_container_meta "$active_meta_file" exists || true)" != "true" ] || [ "$(read_container_meta "$active_meta_file" status || true)" != "running" ]; then
  echo "[Error] Replacement backend container was not left running after a successful update." >&2
  exit 1
fi

if [ "$(read_container_meta "$active_meta_file" id || true)" != "$replacement_runtime_id" ]; then
  echo "[Error] Replacement backend container identity was not preserved after success." >&2
  exit 1
fi

if [ "$(read_container_meta "$backup_meta_file" exists || true)" = "true" ]; then
  echo "[Error] Rollback container was not removed after commit succeeded." >&2
  exit 1
fi

if ! grep -Fq "backend,example.com,172.30.0.99:8000,dockistrate-net" "$BACKEND_PORTS_FILE"; then
  echo "[Error] Backend config was not updated to the replacement container upstream." >&2
  exit 1
fi

if ! grep -Fq 'backend:example.com,-p 18181:80 --label app=seed' "$BACKEND_DOCKER_OPTS_FILE"; then
  echo "[Error] Backend docker opts were not preserved across the successful update." >&2
  exit 1
fi

rollback_name="$(sed -n "s/^subcommand=rename rename ${cname} \\(${cname}-rollback-[0-9-][0-9-]*\\)$/\\1/p" "$docker_log_file" | head -n 1)"
if [ -z "$rollback_name" ]; then
  echo "[Error] Failed to discover the staged rollback container name from the docker log." >&2
  exit 1
fi

if ! grep -Fq "subcommand=stop stop $rollback_name" "$docker_log_file"; then
  echo "[Error] update_backend did not stop the staged rollback container before replacement launch." >&2
  exit 1
fi

if ! grep -Fq "subcommand=rm rm -f $rollback_name" "$docker_log_file"; then
  echo "[Error] update_backend did not remove the stopped rollback container after commit succeeded." >&2
  exit 1
fi

stop_line="$(grep -n "subcommand=stop stop $rollback_name" "$docker_log_file" | head -n 1 | cut -d: -f1 || true)"
run_line="$(grep -n "subcommand=run run -d --name $cname" "$docker_log_file" | head -n 1 | cut -d: -f1 || true)"
if [ -z "$stop_line" ] || [ -z "$run_line" ] || [ "$stop_line" -ge "$run_line" ]; then
  echo "[Error] update_backend did not stop the staged rollback container before running the replacement." >&2
  exit 1
fi

echo "update_backend stops staged rollback containers before replacement launch."
