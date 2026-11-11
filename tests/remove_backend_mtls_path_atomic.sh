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
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/clean_uninstall.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_backend_mtls_guard.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SKIP_DOCKER_CHECKS=true
INTERACTIVE=false

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
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$CERTS_DIR" "$CERTS_DIR/mtls" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"

cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,18180,8000,http,,no,off,,off,auto,,,,,,
EOF_PORTS
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"

cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"

function assert_tampered_mapping_rejected() {
  local label="${1:-}" mapped_path="${2:-}" protected_path="${3:-}"
  local command_name="" output="" status=0

  cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,$mapped_path
EOF_MTLS
  cp "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"

  for command_name in remove_backend clean_all; do
    set +e
    output="$($command_name example.com 2>&1)"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      echo "[Error] ${command_name} accepted ${label} mTLS owner mapping." >&2
      exit 1
    fi
    if ! grep -Fq "persisted mTLS owner mappings are invalid" <<<"$output"; then
      echo "[Error] ${command_name} did not report the ${label} owner-binding failure." >&2
      echo "$output" >&2
      exit 1
    fi
    if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"; then
      echo "[Error] ${command_name} changed backend state after rejecting ${label} mTLS mapping." >&2
      exit 1
    fi
    if ! cmp -s "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"; then
      echo "[Error] ${command_name} changed mTLS state after rejecting ${label} mapping." >&2
      exit 1
    fi
    if [ ! -e "$protected_path" ] && [ ! -L "$protected_path" ]; then
      echo "[Error] ${command_name} removed the protected ${label} mTLS path." >&2
      exit 1
    fi
  done
}

OUTSIDE_MTLS_DIR="$TMP_ROOT/outside-mtls"
mkdir -p "$OUTSIDE_MTLS_DIR"
printf 'keep\n' >"$OUTSIDE_MTLS_DIR/sentinel.txt"
assert_tampered_mapping_rejected "outside-root" "$OUTSIDE_MTLS_DIR" "$OUTSIDE_MTLS_DIR/sentinel.txt"

MTLS_ROOT="$CERTS_DIR/mtls"
printf 'keep\n' >"$MTLS_ROOT/root-sentinel.txt"
assert_tampered_mapping_rejected "root" "$MTLS_ROOT" "$MTLS_ROOT/root-sentinel.txt"

SIBLING_MTLS_DIR="$MTLS_ROOT/other.com"
mkdir -p "$SIBLING_MTLS_DIR"
printf 'keep\n' >"$SIBLING_MTLS_DIR/sentinel.txt"
assert_tampered_mapping_rejected "sibling" "$SIBLING_MTLS_DIR" "$SIBLING_MTLS_DIR/sentinel.txt"

SYMLINK_MTLS_DIR="$MTLS_ROOT/example.com"
ln -s other.com "$SYMLINK_MTLS_DIR"
assert_tampered_mapping_rejected "symlink" "$SYMLINK_MTLS_DIR" "$SIBLING_MTLS_DIR/sentinel.txt"
if [ ! -L "$SYMLINK_MTLS_DIR" ]; then
  echo "[Error] Guarded cleanup removed the symlinked owner path." >&2
  exit 1
fi

# Disabled mTLS has no mapping: canonical fallback must retain the same guard.
printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" >"$BACKEND_MTLS_FILE"
cp "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"
if output="$(remove_backend example.com 2>&1)"; then
  echo '[Error] Removal accepted a disabled authority replaced by a symlink.' >&2
  exit 1
fi
if ! grep -Fq 'ownership is invalid' <<<"$output"; then
  echo "$output" >&2
  exit 1
fi
cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
cmp -s "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"
[ -L "$SYMLINK_MTLS_DIR" ] && [ -f "$SIBLING_MTLS_DIR/sentinel.txt" ]

printf 'Backend cleanup rejects outside, root, sibling, and symlinked mTLS owner mappings atomically.\n'
