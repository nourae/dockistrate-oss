#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
if declare -F get_container_network_names >/dev/null 2>&1; then
  echo "[Error] test setup unexpectedly loaded backend network helpers." >&2
  exit 1
fi
# shellcheck source=../lib/nginx/remove_unused_nginx_networks.sh
source "$ROOT_DIR/lib/nginx/remove_unused_nginx_networks.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_unused_networks.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

DEFAULT_NETWORK="dockistrate-net"
NGINX_CONTAINER_NAME="nginx-proxy"
BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
DOCKER_MOCK_LOG_FILE="${tmp_dir}/docker.log"
PATH="${ROOT_DIR}/tests/mocks:${PATH}"
DOCKER_MOCK_INSPECT_NETWORK_NAMES=$'dockistrate-net\nmy.net'
export PATH DOCKER_MOCK_LOG_FILE DOCKER_MOCK_INSPECT_NETWORK_NAMES

function nginx_container_is_managed() {
  return 0
}

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,network-exact.test,172.30.0.2:18180,myxnet,,,,,,,,,,,,,,,,,
port,network-exact.test,,,,,18180,18180,http,none,no,off,,off,auto,,,,,,
EOF

remove_unused_nginx_networks

if ! grep -Fq 'subcommand=network disconnect my.net nginx-proxy' "$DOCKER_MOCK_LOG_FILE"; then
  echo "[Error] remove_unused_nginx_networks treated my.net as matching required myxnet." >&2
  exit 1
fi
if grep -Fq 'subcommand=network disconnect dockistrate-net nginx-proxy' "$DOCKER_MOCK_LOG_FILE"; then
  echo "[Error] remove_unused_nginx_networks disconnected the default network." >&2
  exit 1
fi

echo "remove-unused-nginx-networks exact matching checks passed."
