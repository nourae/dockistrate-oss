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
source "$ROOT_DIR/lib/ports.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/clean_uninstall.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_clean_all_runtime_rollback.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

ORIG_BACKUP_FILES_ONLY_DEF="$(declare -f backup_files_only | sed '1s/backup_files_only/orig_backup_files_only/')"
eval "$ORIG_BACKUP_FILES_ONLY_DEF"

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

INTERACTIVE=false
ENABLE_AUTO_BACKUPS=false
SKIP_DOCKER_CHECKS=true

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$CERTS_DIR/custom/live/example.com" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,18180,8000,http,none,yes,off,,off,auto,,,,,,
EOF_PORTS

cat >"$BACKEND_DOCKER_OPTS_FILE" <<'EOF_DOCKER_OPTS'
key,docker_options
backend:example.com,--cpus 1
EOF_DOCKER_OPTS

touch "$CERTS_DIR/custom/live/example.com/fullchain.pem"

cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
cp "$BACKEND_DOCKER_OPTS_FILE" "$BACKEND_DOCKER_OPTS_FILE.orig"

backup_files_only_counter_file="$TMP_ROOT/backup_files_only.count"
printf '0\n' >"$backup_files_only_counter_file"

function backup_files_only() {
  local calls=0
  calls="$(cat "$backup_files_only_counter_file")"
  calls=$((calls + 1))
  printf '%s\n' "$calls" >"$backup_files_only_counter_file"
  if [ "$calls" -eq 1 ]; then
    orig_backup_files_only "$@"
  else
    return 1
  fi
}

function create_backup() { :; }
function update_nginx_config() { :; }

function write_container_meta() {
  local file="${1:-}" exists="${2:-false}" name="${3:-}" status="${4:-}"
  {
    printf 'exists=%s\n' "$exists"
    printf 'name=%s\n' "$name"
    printf 'status=%s\n' "$status"
  } >"$file"
}

function read_container_meta() {
  local file="${1:-}" key="${2:-}"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

test_backend_name="backend-example.com"
docker_log_file="$TMP_ROOT/docker_clean_all_runtime_rollback.log"
active_meta_file="$TMP_ROOT/active.meta"
backup_meta_file="$TMP_ROOT/backup.meta"

write_container_meta "$active_meta_file" "true" "$test_backend_name" "running"
write_container_meta "$backup_meta_file" "false" "" ""

function container_exists() {
  local candidate="${1:-}"
  local backup_name backup_exists

  if [ "$candidate" = "$test_backend_name" ]; then
    [ "$(read_container_meta "$active_meta_file" exists || true)" = "true" ]
    return
  fi

  backup_name="$(read_container_meta "$backup_meta_file" name || true)"
  backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ]; then
    [ "$backup_exists" = "true" ]
    return
  fi

  return 1
}

function container_running() {
  local candidate="${1:-}"
  local backup_name

  if [ "$candidate" = "$test_backend_name" ] && [ "$(read_container_meta "$active_meta_file" exists || true)" = "true" ]; then
    [ "$(read_container_meta "$active_meta_file" status || true)" = "running" ]
    return
  fi

  backup_name="$(read_container_meta "$backup_meta_file" name || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ] && [ "$(read_container_meta "$backup_meta_file" exists || true)" = "true" ]; then
    [ "$(read_container_meta "$backup_meta_file" status || true)" = "running" ]
    return
  fi

  return 1
}

function remove_container_and_anonymous_volumes() {
  local candidate="${1:-}"
  printf 'subcommand=rm -f -v %s\n' "$candidate" >>"$docker_log_file"

  if [ "$candidate" = "$test_backend_name" ] && [ "$(read_container_meta "$active_meta_file" exists || true)" = "true" ]; then
    write_container_meta "$active_meta_file" "false" "$test_backend_name" ""
    return 0
  fi

  local backup_name backup_exists
  backup_name="$(read_container_meta "$backup_meta_file" name || true)"
  backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
    write_container_meta "$backup_meta_file" "false" "$backup_name" ""
    return 0
  fi

  return 1
}

function docker() {
  if [ "$#" -gt 1 ]; then
    printf 'subcommand=%s %s\n' "$1" "${*:2}" >>"$docker_log_file"
  else
    printf 'subcommand=%s\n' "$1" >>"$docker_log_file"
  fi
  case "${1:-}" in
  rename)
    local src="${2:-}" dest="${3:-}"
    local active_exists active_status backup_name backup_exists backup_status

    active_exists="$(read_container_meta "$active_meta_file" exists || true)"
    active_status="$(read_container_meta "$active_meta_file" status || true)"
    backup_name="$(read_container_meta "$backup_meta_file" name || true)"
    backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
    backup_status="$(read_container_meta "$backup_meta_file" status || true)"

    if [ "$src" = "$test_backend_name" ]; then
      [ "$active_exists" = "true" ] || return 1
      [ "$backup_exists" = "false" ] || return 1
      write_container_meta "$backup_meta_file" "true" "$dest" "$active_status"
      write_container_meta "$active_meta_file" "false" "$test_backend_name" ""
      return 0
    fi

    if [ -n "$backup_name" ] && [ "$src" = "$backup_name" ] && [ "$dest" = "$test_backend_name" ]; then
      [ "$backup_exists" = "true" ] || return 1
      [ "$active_exists" = "false" ] || return 1
      write_container_meta "$active_meta_file" "true" "$test_backend_name" "$backup_status"
      write_container_meta "$backup_meta_file" "false" "$backup_name" ""
      return 0
    fi

    return 1
    ;;
  stop)
    local target="${2:-}"
    local backup_name backup_exists
    backup_name="$(read_container_meta "$backup_meta_file" name || true)"
    backup_exists="$(read_container_meta "$backup_meta_file" exists || true)"
    if [ -n "$backup_name" ] && [ "$target" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
      write_container_meta "$backup_meta_file" "true" "$backup_name" "exited"
      return 0
    fi
    return 1
    ;;
  start)
    local target="${2:-}"
    if [ "$target" = "$test_backend_name" ] && [ "$(read_container_meta "$active_meta_file" exists || true)" = "true" ]; then
      write_container_meta "$active_meta_file" "true" "$test_backend_name" "running"
      return 0
    fi
    return 1
    ;;
  *)
    return 1
    ;;
  esac
}

set +e
output="$(clean_all example.com 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] clean_all succeeded unexpectedly when commit finalization failed." >&2
  exit 1
fi

if ! grep -Fq "failed. Rolled back." <<<"$output"; then
  echo "[Error] Expected rollback message from clean_all commit failure." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"; then
  echo "[Error] BACKEND_PORTS_FILE was not restored after clean_all rollback." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_DOCKER_OPTS_FILE" "$BACKEND_DOCKER_OPTS_FILE.orig"; then
  echo "[Error] BACKEND_DOCKER_OPTS_FILE was not restored after clean_all rollback." >&2
  exit 1
fi

if [ "$(read_container_meta "$active_meta_file" exists || true)" != "true" ]; then
  echo "[Error] Backend container was not restored after clean_all rollback." >&2
  exit 1
fi

if [ "$(read_container_meta "$active_meta_file" status || true)" != "running" ]; then
  echo "[Error] Backend container was not restarted after clean_all rollback." >&2
  exit 1
fi

if [ "$(read_container_meta "$backup_meta_file" exists || true)" = "true" ]; then
  echo "[Error] Staged rollback container should not remain after clean_all rollback." >&2
  exit 1
fi

rollback_name="$(sed -n "s/^subcommand=rename ${test_backend_name} \\(${test_backend_name}-rollback-[0-9-][0-9-]*\\)$/\\1/p" "$docker_log_file" | head -n 1)"
if [ -z "$rollback_name" ]; then
  echo "[Error] Failed to discover the staged cleanup rollback container name for clean_all." >&2
  exit 1
fi

if ! grep -Fq "subcommand=stop $rollback_name" "$docker_log_file"; then
  echo "[Error] clean_all did not stop the staged rollback container before commit." >&2
  exit 1
fi

if ! grep -Fq "subcommand=rename $rollback_name $test_backend_name" "$docker_log_file"; then
  echo "[Error] clean_all rollback did not restore the original backend container name." >&2
  exit 1
fi

if ! grep -Fq "subcommand=start $test_backend_name" "$docker_log_file"; then
  echo "[Error] clean_all rollback did not restart the restored backend container." >&2
  exit 1
fi

if grep -Fq "subcommand=rm -f -v $rollback_name" "$docker_log_file"; then
  echo "[Error] clean_all should not permanently remove the staged rollback container before commit succeeds." >&2
  exit 1
fi

printf 'Clean-all runtime rollback restores staged backend deletions after commit failure.\n'
