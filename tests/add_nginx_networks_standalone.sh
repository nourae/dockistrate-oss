#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
if declare -F container_attached_to_network >/dev/null 2>&1 || \
  declare -F get_container_network_ip >/dev/null 2>&1 || \
  declare -F get_container_network_names >/dev/null 2>&1; then
  echo "[Error] test setup unexpectedly loaded backend network helpers." >&2
  exit 1
fi
# shellcheck source=../lib/nginx/common.sh
source "$ROOT_DIR/lib/nginx/common.sh"
if declare -F container_attached_to_network >/dev/null 2>&1; then
  echo "[Error] nginx common unexpectedly loaded backend attachment helpers." >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_add_nginx_networks.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

DEFAULT_NETWORK="dockistrate-net"
NGINX_CONTAINER_NAME="nginx-proxy"
BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
DOCKER_MOCK_LOG_FILE="${tmp_dir}/docker.log"
DOCKER_MOCK_RUNTIME_DIR="${tmp_dir}/docker-runtime"
DOCKER_MOCK_NETWORK_NAMES=$'dockistrate-net\napp.net'
PATH="${ROOT_DIR}/tests/mocks:${PATH}"
export PATH DOCKER_MOCK_LOG_FILE DOCKER_MOCK_RUNTIME_DIR DOCKER_MOCK_NETWORK_NAMES

function nginx_container_is_managed() {
  return 0
}

docker run --name "$NGINX_CONTAINER_NAME" --network "$DEFAULT_NETWORK" nginx:alpine >/dev/null

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,standalone-network.test,172.30.0.2:18180,app.net,,,,,,,,,,,,,,,,,
EOF

add_nginx_networks

if ! grep -Fq 'subcommand=network connect app.net nginx-proxy' "$DOCKER_MOCK_LOG_FILE"; then
  echo "[Error] add_nginx_networks did not connect nginx to the backend network." >&2
  exit 1
fi

if ! docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s\n" $k}}{{end}}' "$NGINX_CONTAINER_NAME" | grep -Fxq 'app.net'; then
  echo "[Error] add_nginx_networks did not leave nginx attached to the backend network." >&2
  exit 1
fi

echo "add-nginx-networks standalone helper checks passed."
