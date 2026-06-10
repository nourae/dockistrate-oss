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
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_dh_fail.XXXXXX")"
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
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

INTERACTIVE=false

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,base.test,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
port,base.test,,,,,80,18180,http,,no,off,,off,auto,,,,,,
EOF_PORTS

cat >"$BACKEND_ALIASES_FILE" <<'EOF_ALIASES'
record_type,hostname,target_domain
alias,www.base.test,base.test
EOF_ALIASES

inherit_file="$(dedicated_host_inheritance_file)"
cat >"$inherit_file" <<'EOF_INHERIT'
hostname,inherit_mtls,inherit_acl,inherit_security_rules,inherit_headers,inherit_paths
legacy.base.test,yes,yes,yes,yes,yes
EOF_INHERIT

cp "$BACKEND_ALIASES_FILE" "$BACKEND_ALIASES_FILE.orig"
cp "$inherit_file" "$inherit_file.orig"

function create_backup() { :; }
function update_nginx_config() { return 1; }

set +e
(add_dedicated_host app.base.test base.test yes no yes no yes)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] add_dedicated_host succeeded unexpectedly." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_ALIASES_FILE" "$BACKEND_ALIASES_FILE.orig"; then
  echo "[Error] Dedicated host alias state was not rolled back." >&2
  exit 1
fi

if ! cmp -s "$inherit_file" "$inherit_file.orig"; then
  echo "[Error] Dedicated host inheritance state was not rolled back." >&2
  exit 1
fi

printf 'Dedicated host transaction rollback checks passed.\n'
