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
source "$ROOT_DIR/lib/clean_uninstall.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_uninstall_runtime_rollback.XXXXXX")"
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
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

INTERACTIVE=true
ENABLE_AUTO_BACKUPS=false

function read_with_editing() {
  local prompt="${1:-}" __out="${2:-}"
  printf -v "$__out" '%s' "YES"
  return 0
}

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$CAPTURE_DIR" "$ACME_WEBROOT_DIR" "$CERTS_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS

touch "$NGINX_CONFIG_DIR/backends.conf"
touch "$CERTS_DIR/cert.pem"

cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
cp "$NGINX_CONFIG_DIR/backends.conf" "$NGINX_CONFIG_DIR/backends.conf.orig"
cp "$CERTS_DIR/cert.pem" "$CERTS_DIR/cert.pem.orig"

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

docker_log_file="$TMP_ROOT/docker_uninstall_runtime_rollback.log"
backend_name="backend-example.com"
nginx_meta_file="$TMP_ROOT/nginx.active.meta"
nginx_backup_meta_file="$TMP_ROOT/nginx.backup.meta"
backend_meta_file="$TMP_ROOT/backend.active.meta"
backend_backup_meta_file="$TMP_ROOT/backend.backup.meta"

write_container_meta "$nginx_meta_file" "true" "$NGINX_CONTAINER_NAME" "running"
write_container_meta "$nginx_backup_meta_file" "false" "" ""
write_container_meta "$backend_meta_file" "true" "$backend_name" "running"
write_container_meta "$backend_backup_meta_file" "false" "" ""

function _active_meta_file_for_original() {
  local original="${1:-}"
  case "$original" in
  "$NGINX_CONTAINER_NAME") printf '%s\n' "$nginx_meta_file" ;;
  "$backend_name") printf '%s\n' "$backend_meta_file" ;;
  *) return 1 ;;
  esac
}

function _backup_meta_file_for_original() {
  local original="${1:-}"
  case "$original" in
  "$NGINX_CONTAINER_NAME") printf '%s\n' "$nginx_backup_meta_file" ;;
  "$backend_name") printf '%s\n' "$backend_backup_meta_file" ;;
  *) return 1 ;;
  esac
}

function _find_original_name_for_candidate() {
  local candidate="${1:-}" backup_name=""
  for original in "$NGINX_CONTAINER_NAME" "$backend_name"; do
    if [ "$candidate" = "$original" ]; then
      printf '%s\n' "$original"
      return 0
    fi
    backup_name="$(read_container_meta "$(_backup_meta_file_for_original "$original")" name || true)"
    if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ]; then
      printf '%s\n' "$original"
      return 0
    fi
  done
  return 1
}

function container_exists() {
  local candidate="${1:-}" original="" active_meta="" backup_meta="" backup_name=""

  if ! original="$(_find_original_name_for_candidate "$candidate" 2>/dev/null)"; then
    return 1
  fi

  active_meta="$(_active_meta_file_for_original "$original")"
  if [ "$candidate" = "$original" ]; then
    [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]
    return
  fi

  backup_meta="$(_backup_meta_file_for_original "$original")"
  backup_name="$(read_container_meta "$backup_meta" name || true)"
  [ -n "$backup_name" ] || return 1
  [ "$(read_container_meta "$backup_meta" exists || true)" = "true" ]
}

function container_running() {
  local candidate="${1:-}" original="" active_meta="" backup_meta="" backup_name=""

  if ! original="$(_find_original_name_for_candidate "$candidate" 2>/dev/null)"; then
    return 1
  fi

  active_meta="$(_active_meta_file_for_original "$original")"
  if [ "$candidate" = "$original" ] && [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]; then
    [ "$(read_container_meta "$active_meta" status || true)" = "running" ]
    return
  fi

  backup_meta="$(_backup_meta_file_for_original "$original")"
  backup_name="$(read_container_meta "$backup_meta" name || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ] && [ "$(read_container_meta "$backup_meta" exists || true)" = "true" ]; then
    [ "$(read_container_meta "$backup_meta" status || true)" = "running" ]
    return
  fi

  return 1
}

function remove_container_and_anonymous_volumes() {
  local candidate="${1:-}" original="" active_meta="" backup_meta="" backup_name=""
  printf 'subcommand=rm -f -v %s\n' "$candidate" >>"$docker_log_file"

  if ! original="$(_find_original_name_for_candidate "$candidate" 2>/dev/null)"; then
    return 1
  fi

  active_meta="$(_active_meta_file_for_original "$original")"
  if [ "$candidate" = "$original" ] && [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]; then
    write_container_meta "$active_meta" "false" "$original" ""
    return 0
  fi

  backup_meta="$(_backup_meta_file_for_original "$original")"
  backup_name="$(read_container_meta "$backup_meta" name || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ] && [ "$(read_container_meta "$backup_meta" exists || true)" = "true" ]; then
    write_container_meta "$backup_meta" "false" "$backup_name" ""
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
    local src="${2:-}" dest="${3:-}" original="" active_meta="" backup_meta=""
    local active_exists active_status backup_exists backup_name backup_status

    if [ "$src" = "$NGINX_CONTAINER_NAME" ] || [ "$src" = "$backend_name" ]; then
      original="$src"
    else
      original="$(_find_original_name_for_candidate "$src" 2>/dev/null || true)"
    fi
    [ -n "$original" ] || return 1

    active_meta="$(_active_meta_file_for_original "$original")"
    backup_meta="$(_backup_meta_file_for_original "$original")"
    active_exists="$(read_container_meta "$active_meta" exists || true)"
    active_status="$(read_container_meta "$active_meta" status || true)"
    backup_exists="$(read_container_meta "$backup_meta" exists || true)"
    backup_name="$(read_container_meta "$backup_meta" name || true)"
    backup_status="$(read_container_meta "$backup_meta" status || true)"

    if [ "$src" = "$original" ]; then
      [ "$active_exists" = "true" ] || return 1
      [ "$backup_exists" = "false" ] || return 1
      write_container_meta "$backup_meta" "true" "$dest" "$active_status"
      write_container_meta "$active_meta" "false" "$original" ""
      return 0
    fi

    if [ -n "$backup_name" ] && [ "$src" = "$backup_name" ] && [ "$dest" = "$original" ]; then
      [ "$backup_exists" = "true" ] || return 1
      [ "$active_exists" = "false" ] || return 1
      write_container_meta "$active_meta" "true" "$original" "$backup_status"
      write_container_meta "$backup_meta" "false" "$backup_name" ""
      return 0
    fi

    return 1
    ;;
  stop)
    local target="${2:-}" original="" backup_meta="" backup_name=""
    original="$(_find_original_name_for_candidate "$target" 2>/dev/null || true)"
    [ -n "$original" ] || return 1
    backup_meta="$(_backup_meta_file_for_original "$original")"
    backup_name="$(read_container_meta "$backup_meta" name || true)"
    if [ -n "$backup_name" ] && [ "$target" = "$backup_name" ] && [ "$(read_container_meta "$backup_meta" exists || true)" = "true" ]; then
      write_container_meta "$backup_meta" "true" "$backup_name" "exited"
      return 0
    fi
    return 1
    ;;
  start)
    local target="${2:-}" original="" active_meta=""
    if [ "$target" = "$NGINX_CONTAINER_NAME" ] || [ "$target" = "$backend_name" ]; then
      original="$target"
    fi
    [ -n "$original" ] || return 1
    active_meta="$(_active_meta_file_for_original "$original")"
    if [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]; then
      write_container_meta "$active_meta" "true" "$original" "running"
      return 0
    fi
    return 1
    ;;
  *)
    return 1
    ;;
  esac
}

function nginx_container_conflict_exists() { return 1; }
function nginx_container_is_managed() {
  container_exists "$NGINX_CONTAINER_NAME"
}

set +e
output="$(uninstall_all --scope backend 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] uninstall_all succeeded unexpectedly when commit finalization failed." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"; then
  echo "[Error] BACKEND_PORTS_FILE was not restored after uninstall_all rollback." >&2
  exit 1
fi

if [ ! -f "$NGINX_CONFIG_DIR/backends.conf" ] || ! cmp -s "$NGINX_CONFIG_DIR/backends.conf" "$NGINX_CONFIG_DIR/backends.conf.orig"; then
  echo "[Error] Nginx config artifact was not restored after uninstall_all rollback." >&2
  exit 1
fi

if [ ! -f "$CERTS_DIR/cert.pem" ] || ! cmp -s "$CERTS_DIR/cert.pem" "$CERTS_DIR/cert.pem.orig"; then
  echo "[Error] Cert material was not restored after uninstall_all rollback." >&2
  exit 1
fi

for file in "$nginx_meta_file" "$backend_meta_file"; do
  if [ "$(read_container_meta "$file" exists || true)" != "true" ]; then
    echo "[Error] A staged container was not restored after uninstall_all rollback." >&2
    exit 1
  fi
  if [ "$(read_container_meta "$file" status || true)" != "running" ]; then
    echo "[Error] A restored container was not restarted after uninstall_all rollback." >&2
    exit 1
  fi
done

for file in "$nginx_backup_meta_file" "$backend_backup_meta_file"; do
  if [ "$(read_container_meta "$file" exists || true)" = "true" ]; then
    echo "[Error] Staged rollback containers should not remain after uninstall_all rollback." >&2
    exit 1
  fi
done

nginx_rollback_name="$(sed -n "s/^subcommand=rename ${NGINX_CONTAINER_NAME} \\(${NGINX_CONTAINER_NAME}-rollback-[0-9-][0-9-]*\\)$/\\1/p" "$docker_log_file" | head -n 1)"
backend_rollback_name="$(sed -n "s/^subcommand=rename ${backend_name} \\(${backend_name}-rollback-[0-9-][0-9-]*\\)$/\\1/p" "$docker_log_file" | head -n 1)"

if [ -z "$nginx_rollback_name" ] || [ -z "$backend_rollback_name" ]; then
  echo "[Error] Failed to discover staged rollback container names for uninstall_all." >&2
  exit 1
fi

for expected in \
  "subcommand=stop $nginx_rollback_name" \
  "subcommand=stop $backend_rollback_name" \
  "subcommand=rename $nginx_rollback_name $NGINX_CONTAINER_NAME" \
  "subcommand=rename $backend_rollback_name $backend_name" \
  "subcommand=start $NGINX_CONTAINER_NAME" \
  "subcommand=start $backend_name"; do
  if ! grep -Fq "$expected" "$docker_log_file"; then
    echo "[Error] Missing expected runtime rollback operation: $expected" >&2
    exit 1
  fi
done

if grep -Fq "subcommand=rm -f -v $nginx_rollback_name" "$docker_log_file" || \
  grep -Fq "subcommand=rm -f -v $backend_rollback_name" "$docker_log_file"; then
  echo "[Error] uninstall_all should not permanently remove staged rollback containers before commit succeeds." >&2
  exit 1
fi

printf 'Uninstall-all runtime rollback restores staged nginx/backend deletions after commit failure.\n'
