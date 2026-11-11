#!/usr/bin/env bash
# Fixture globals are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/ports.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx_directives.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_all_paths_validation.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

STATE_DIR="$TMP_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
mkdir -p "$PATH_HEADER_DIR" "$TMP_DIR" "$BACKUP_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:8080,dockistrate-net,,,,,,,,,,,,,,,,,
path,example.com,,,/app,../../victim,8080,,,,inherit,off,,,,prefix,100,,none,-,auto
EOF_PORTS
cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.before"

victim_file="$NGINX_CONFIG_DIR/victim.conf"
printf 'keep\n' >"$victim_file"

set +e
output="$(remove_all_path_options example.com 2>&1)"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "[Error] remove_all_path_options accepted a traversal header-set name." >&2
  exit 1
fi
if ! grep -Fq "Invalid persisted path header set at line 3" <<<"$output"; then
  echo "[Error] remove_all_path_options did not report the invalid persisted header set." >&2
  echo "$output" >&2
  exit 1
fi
if [ ! -f "$victim_file" ]; then
  echo "[Error] remove_all_path_options deleted a file outside PATH_HEADER_DIR." >&2
  exit 1
fi
if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.before"; then
  echo "[Error] remove_all_path_options mutated state before rejecting the header set." >&2
  exit 1
fi

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:8080,dockistrate-net,,,,,,,,,,,,,,,,,
backend,other.example.com,127.0.0.1:8081,dockistrate-net,,,,,,,,,,,,,,,,,
path,example.com,,,/app,shared,8080,,,,inherit,off,,,,prefix,100,,none,-,auto
EOF_PORTS
printf 'shared header\n' >"$PATH_HEADER_DIR/shared.conf"

# Inject a cooperating writer's completed row exactly when cleanup obtains the
# shared lock. The locked scan must observe it and preserve the shared include.
function _config_begin_runtime_prep_lock_if_needed() {
  local __started_var="${1:-}"
  acquire_transaction_lock || return 1
  CONFIG_RUNTIME_PREP_LOCK_HELD="true"
  CONFIG_RUNTIME_PREP_LOCK_OWNER_PID="$$"
  printf -v "$__started_var" '%s' "true"
  printf '%s\n' 'path,other.example.com,,,/other,shared,8080,,,,inherit,off,,,,prefix,100,,none,-,auto' >>"$BACKEND_PORTS_FILE"
}

function create_backup() { :; }
function update_nginx_config() { :; }

remove_all_path_options example.com >/dev/null
if [ ! -f "$PATH_HEADER_DIR/shared.conf" ]; then
  echo "[Error] remove_all_path_options deleted an include shared by a row visible at lock acquisition." >&2
  exit 1
fi
if grep -Fq 'path,example.com,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] remove_all_path_options did not remove the requested domain path." >&2
  exit 1
fi
if ! grep -Fq 'path,other.example.com,,,/other,shared,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] remove_all_path_options did not preserve the concurrent shared-header consumer." >&2
  exit 1
fi

printf 'Path-option cleanup rejects traversal and preserves consumers visible at lock acquisition.\n'
