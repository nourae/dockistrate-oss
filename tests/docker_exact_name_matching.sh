#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-docker-exact.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-} ${2:-}" in
"ps -a")
  printf '%s\n' "${DOCKER_PS_NAMES:-}"
  ;;
"network ls")
  printf '%s\n' "${DOCKER_NETWORK_NAMES:-}"
  ;;
"network create")
  printf '%s\n' "${3:-}" >>"${DOCKER_CREATE_LOG:?}"
  ;;
*)
  printf 'unexpected docker command: %s\n' "$*" >&2
  exit 2
  ;;
esac
EOF_DOCKER
chmod +x "$TMP_DIR/docker"

PATH="$TMP_DIR:$PATH"
DOCKER_CREATE_LOG="$TMP_DIR/network-create.log"
export PATH DOCKER_CREATE_LOG

# shellcheck source=../lib/utils/docker.sh
source "$ROOT_DIR/lib/utils/docker.sh"

DOCKER_PS_NAMES="myxnet"
export DOCKER_PS_NAMES
if container_exists "my.net"; then
  echo "[Error] container_exists matched a similar non-exact container name." >&2
  exit 1
fi

DOCKER_PS_NAMES=$'myxnet\nmy.net'
export DOCKER_PS_NAMES
if ! container_exists "my.net"; then
  echo "[Error] container_exists did not match the exact container name." >&2
  exit 1
fi

: >"$DOCKER_CREATE_LOG"
DOCKER_NETWORK_NAMES="myxnet"
export DOCKER_NETWORK_NAMES
ensure_network_exists "my.net"
if ! grep -Fxq "my.net" "$DOCKER_CREATE_LOG"; then
  echo "[Error] ensure_network_exists did not create the missing exact network." >&2
  exit 1
fi

: >"$DOCKER_CREATE_LOG"
DOCKER_NETWORK_NAMES=$'myxnet\nmy.net'
export DOCKER_NETWORK_NAMES
ensure_network_exists "my.net"
if [ -s "$DOCKER_CREATE_LOG" ]; then
  echo "[Error] ensure_network_exists created a network despite an exact match." >&2
  exit 1
fi

echo "[tests] docker_exact_name_matching.sh: PASS"
