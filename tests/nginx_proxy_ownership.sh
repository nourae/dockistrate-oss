#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="${ROOT_DIR}/tests/mocks:$PATH"

# shellcheck disable=SC1090
source "${ROOT_DIR}/lib/config/common.sh"
# shellcheck disable=SC1090
source "${ROOT_DIR}/lib/utils/docker.sh"
# shellcheck disable=SC1090
source "${ROOT_DIR}/lib/nginx/common.sh"

function reset_proxy_mock() {
  unset DOCKER_MOCK_INSPECT_LABELS
  unset DOCKER_MOCK_INSPECT_MOUNTS
  unset DOCKER_MOCK_MISSING_LABEL_OUTPUT
  export DOCKER_MOCK_PROXY_STATE_DIR="${STATE_DIR}"
  export DOCKER_MOCK_PS_NAMES="nginx-proxy"
  export DOCKER_MOCK_PROXY_MANAGED="true"
}

reset_proxy_mock
if ! nginx_container_is_managed; then
  echo "[Error] Labeled nginx-proxy should be recognized as Dockistrate-managed." >&2
  exit 1
fi
if nginx_container_conflict_exists; then
  echo "[Error] Labeled nginx-proxy should not be treated as a conflict." >&2
  exit 1
fi

reset_proxy_mock
export DOCKER_MOCK_PROXY_STATE_DIR="/tmp/foreign-dockistrate-state"
if nginx_container_is_managed; then
  echo "[Error] Labeled nginx-proxy from another checkout should not be recognized as managed." >&2
  exit 1
fi
if ! nginx_container_conflict_exists; then
  echo "[Error] Labeled nginx-proxy from another checkout should be treated as a conflict." >&2
  exit 1
fi

reset_proxy_mock
export DOCKER_MOCK_PROXY_MANAGED="false"
export DOCKER_MOCK_INSPECT_MOUNTS="$(cat <<EOF
${NGINX_CONFIG_DIR}|${NGINX_CONTAINER_CONF_ROOT}|false
${CERTS_DIR}|/etc/letsencrypt|false
${ACME_WEBROOT_DIR}|/var/www/certbot|false
EOF
)"
if ! nginx_container_is_managed; then
  echo "[Error] Legacy nginx-proxy with Dockistrate mount signature should be recognized as managed." >&2
  exit 1
fi

reset_proxy_mock
export DOCKER_MOCK_PROXY_MANAGED="false"
export DOCKER_MOCK_MISSING_LABEL_OUTPUT="<no value>"
export DOCKER_MOCK_INSPECT_MOUNTS="$(cat <<EOF
${NGINX_CONFIG_DIR}|${NGINX_CONTAINER_CONF_ROOT}|false
${CERTS_DIR}|/etc/letsencrypt|false
${ACME_WEBROOT_DIR}|/var/www/certbot|false
EOF
)"
if ! nginx_container_is_managed; then
  echo "[Error] Legacy nginx-proxy with <no value> label output should still be recognized as managed." >&2
  exit 1
fi
if nginx_container_conflict_exists; then
  echo "[Error] Legacy nginx-proxy with <no value> label output should not be treated as a conflict." >&2
  exit 1
fi

reset_proxy_mock
export DOCKER_MOCK_PROXY_MANAGED="false"
export DOCKER_MOCK_INSPECT_MOUNTS="/tmp/other|/etc/nginx/dockistrate|false"
if nginx_container_is_managed; then
  echo "[Error] Unrelated nginx-proxy should not be recognized as managed." >&2
  exit 1
fi
if ! nginx_container_conflict_exists; then
  echo "[Error] Unrelated nginx-proxy should be detected as a conflict." >&2
  exit 1
fi

echo "nginx proxy ownership checks passed."
