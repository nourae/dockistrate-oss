#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backends/common.sh
source "$ROOT_DIR/lib/backends/common.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_backend_refresh_header.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

STATE_BACKEND_PORTS_HEADER="record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location"
BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
DOCKER_MOCK_LOG_FILE="${tmp_dir}/docker.log"
PATH="${ROOT_DIR}/tests/mocks:${PATH}"
SKIP_DOCKER_CHECKS=false
export PATH SKIP_DOCKER_CHECKS DOCKER_MOCK_LOG_FILE

function create_backup() {
  return 0
}

function log_msg() {
  return 0
}

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,refresh-header.test,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
port,refresh-header.test,,,,,18180,18180,http,none,no,off,,off,auto,,,,,,
EOF

DOCKER_MOCK_PS_NAMES='backend-refresh-header.test'
DOCKER_MOCK_INSPECT_NETWORK_IP='10.0.0.55'
export DOCKER_MOCK_PS_NAMES DOCKER_MOCK_INSPECT_NETWORK_IP

refresh_backend_ips

first_line="$(head -n 1 "$BACKEND_PORTS_FILE" | tr -d '\r')"
if [ "$first_line" != "$STATE_BACKEND_PORTS_HEADER" ]; then
  echo "[Error] refresh_backend_ips dropped CSV header." >&2
  exit 1
fi
if ! grep -Fq 'backend,refresh-header.test,10.0.0.55:18180,dockistrate-net' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_ips did not update backend upstream as expected." >&2
  exit 1
fi

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,refresh-header.test,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
port,refresh-header.test,,,,,18180,18180,http,none,no,off,,off,auto,,,,,,
EOF

DOCKER_MOCK_INSPECT_NETWORK_NAMES='custom-net'
DOCKER_MOCK_INSPECT_NETWORK_IP='10.0.0.88'
export DOCKER_MOCK_INSPECT_NETWORK_NAMES DOCKER_MOCK_INSPECT_NETWORK_IP

refresh_backend_networks

first_line="$(head -n 1 "$BACKEND_PORTS_FILE" | tr -d '\r')"
if [ "$first_line" != "$STATE_BACKEND_PORTS_HEADER" ]; then
  echo "[Error] refresh_backend_networks dropped CSV header." >&2
  exit 1
fi
if ! grep -Fq 'backend,refresh-header.test,10.0.0.88:18180,custom-net' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_networks did not update backend network/upstream as expected." >&2
  exit 1
fi

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,refresh-header.test,127.0.0.1:18180,custom-net,,,,,,,,,,,,,,,,,
port,refresh-header.test,,,,,18180,18180,http,none,no,off,,off,auto,,,,,,
EOF

DOCKER_MOCK_INSPECT_NETWORK_NAMES=$'dockistrate-net\ncustom-net'
DOCKER_MOCK_INSPECT_NETWORK_MAP='dockistrate-net=10.0.0.10,custom-net=10.0.0.20'
unset DOCKER_MOCK_INSPECT_NETWORK_IP
export DOCKER_MOCK_INSPECT_NETWORK_NAMES DOCKER_MOCK_INSPECT_NETWORK_MAP

refresh_backend_ips

first_line="$(head -n 1 "$BACKEND_PORTS_FILE" | tr -d '\r')"
if [ "$first_line" != "$STATE_BACKEND_PORTS_HEADER" ]; then
  echo "[Error] refresh_backend_ips with multiple networks dropped CSV header." >&2
  exit 1
fi
if ! grep -Fq 'backend,refresh-header.test,10.0.0.20:18180,custom-net' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_ips did not use the stored network IP when multiple networks were attached." >&2
  exit 1
fi
if grep -Fq '10.0.0.10:18180' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_ips used the wrong network IP." >&2
  exit 1
fi

echo "Backend refresh header preservation checks passed."
