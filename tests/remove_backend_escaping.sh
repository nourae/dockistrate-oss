#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/ports/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends.sh"
# Explicit removal also resolves retained authority material when mTLS is off.
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"

ESCAPING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remove_backend_escaping.d"
if [ -d "$ESCAPING_DIR" ]; then
  for stub_file in "$ESCAPING_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$stub_file"
  done
fi

INTERACTIVE=false
SKIP_DOCKER_CHECKS=true

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

STATE_DIR="$TMP_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
CERTS_DIR="$STATE_DIR/certs"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR"

BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"

override_ports_content='record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
backend,examplex.com,10.0.0.6:8001,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,18180,8000,http,none,yes,off,,off,auto,,,,,,
port,examplex.com,,,,,8081,8001,http,none,yes,off,,off,auto,,,,,,
path,example.com,,,/app,customset,18180,,,,inherit,off,,,,prefix,100,,none,-,auto
path,examplex.com,,,/app,customset,8081,,,,inherit,off,,,,prefix,100,,none,-,auto'

printf '%s\n' "$override_ports_content" >"$BACKEND_PORTS_FILE"

set_backend_docker_opts "backend:example.com" "--label app=example"
set_backend_docker_opts "backend:examplex.com" "--label app=examplex"

remove_backend "example.com"

if grep -q '^backend,example\.com,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] backend row for example.com should have been removed" >&2
  exit 1
fi

if grep -q '^port,example\.com,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] port row for example.com should have been removed" >&2
  exit 1
fi

if grep -q '^path,example\.com,,,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] path row for example.com should have been removed" >&2
  exit 1
fi

if ! grep -q '^backend,examplex.com,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] backend row for examplex.com should remain" >&2
  exit 1
fi

if ! grep -q '^port,examplex.com,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] port row for examplex.com should remain" >&2
  exit 1
fi

if ! grep -q '^path,examplex.com,,,' "$BACKEND_PORTS_FILE"; then
  echo "[Error] path row for examplex.com should remain" >&2
  exit 1
fi

if [ -f "$BACKEND_DOCKER_OPTS_FILE" ] && grep -q '^example\.com,' "$BACKEND_DOCKER_OPTS_FILE"; then
  echo "[Error] docker opts entry for example.com should have been removed" >&2
  exit 1
fi

if ! grep -q '^examplex.com,' "$BACKEND_DOCKER_OPTS_FILE"; then
  echo "[Error] docker opts entry for examplex.com should remain" >&2
  exit 1
fi

PATH_HEADER_DIR="$CONFIG_DIR/path_headers"
mkdir -p "$PATH_HEADER_DIR"
victim_file="$CONFIG_DIR/victim.conf"
printf 'keep\n' >"$victim_file"
cat >"$BACKEND_PORTS_FILE" <<'EOF_INVALID_PATH'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
path,example.com,,,/app,../victim,18180,,,,inherit,off,,,,prefix,100,,none,-,auto
EOF_INVALID_PATH
cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.invalid-before"

set +e
invalid_output="$(remove_backend example.com 2>&1)"
invalid_status=$?
set -e
if [ "$invalid_status" -eq 0 ]; then
  echo "[Error] remove_backend accepted an invalid persisted path header set." >&2
  exit 1
fi
if ! grep -Fq "Invalid persisted path header set at line 3" <<<"$invalid_output"; then
  echo "[Error] remove_backend did not report the invalid persisted path header set." >&2
  echo "$invalid_output" >&2
  exit 1
fi
if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.invalid-before"; then
  echo "[Error] remove_backend mutated state before rejecting the path header set." >&2
  exit 1
fi
if [ ! -f "$victim_file" ]; then
  echo "[Error] remove_backend deleted a file outside PATH_HEADER_DIR." >&2
  exit 1
fi

echo "remove_backend escaping regression checks passed."
