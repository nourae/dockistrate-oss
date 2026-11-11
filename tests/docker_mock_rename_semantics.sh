#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_docker_mock_rename.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_RUNTIME_DIR="${TMP_ROOT}/runtime"
mkdir -p "$MOCK_RUNTIME_DIR"

function run_mock_docker() {
  DOCKER_MOCK_RUNTIME_DIR="$MOCK_RUNTIME_DIR" "$BASH" "$ROOT_DIR/tests/mocks/docker" "$@"
}

launch_token="0123456789abcdef0123456789abcdef"
printf 'status=running\nlabels=com.dockistrate.backend-launch=%s\nmounts=\n' "$launch_token" >"${MOCK_RUNTIME_DIR}/source.meta"
source_id="$(run_mock_docker inspect -f '{{.Id}}' source)"
if [ "${#source_id}" -ne 64 ]; then
  echo "[Error] Docker mock should assign a full container ID." >&2
  exit 1
fi
if ! run_mock_docker rename source renamed; then
  echo "[Error] Expected docker mock rename to succeed for an existing source and free destination." >&2
  exit 1
fi
if [ -e "${MOCK_RUNTIME_DIR}/source.meta" ] || [ ! -e "${MOCK_RUNTIME_DIR}/renamed.meta" ]; then
  echo "[Error] Successful docker mock rename did not move the source meta file to the destination name." >&2
  exit 1
fi

if run_mock_docker rename missing renamed-again; then
  echo "[Error] Docker mock rename should fail when the source container is missing." >&2
  exit 1
fi
if [ -e "${MOCK_RUNTIME_DIR}/renamed-again.meta" ]; then
  echo "[Error] Docker mock rename created a destination meta file even though the source was missing." >&2
  exit 1
fi

printf 'status=running\nlabels=\nmounts=\n' >"${MOCK_RUNTIME_DIR}/busy-source.meta"
printf 'status=running\nlabels=keep=true\nmounts=\n' >"${MOCK_RUNTIME_DIR}/busy-target.meta"
run_mock_docker inspect -f '{{.Id}}' busy-source >/dev/null
run_mock_docker inspect -f '{{.Id}}' busy-target >/dev/null
busy_target_before="$(cat "${MOCK_RUNTIME_DIR}/busy-target.meta")"
if run_mock_docker rename busy-source busy-target; then
  echo "[Error] Docker mock rename should fail when the destination container name already exists." >&2
  exit 1
fi
if [ ! -e "${MOCK_RUNTIME_DIR}/busy-source.meta" ]; then
  echo "[Error] Docker mock rename removed the source meta file even though the destination already existed." >&2
  exit 1
fi
if [ "$(cat "${MOCK_RUNTIME_DIR}/busy-target.meta")" != "$busy_target_before" ]; then
  echo "[Error] Docker mock rename overwrote the destination meta file when the destination already existed." >&2
  exit 1
fi

if [ "$(run_mock_docker inspect -f '{{.Id}}' renamed)" != "$source_id" ] ||
  [ "$(run_mock_docker inspect -f '{{.Name}}' "$source_id")" != /renamed ]; then
  echo "[Error] Docker mock changed a container's identity when renamed." >&2
  exit 1
fi
if [ "$(run_mock_docker ps -a --no-trunc --filter "label=com.dockistrate.backend-launch=$launch_token" --format '{{.ID}}')" != "$source_id" ] ||
  [ "$(run_mock_docker inspect -f '{{.Id}} {{index .Config.Labels "com.dockistrate.backend-launch"}}' "$source_id")" != "$source_id $launch_token" ]; then
  echo "[Error] Docker mock label filtering and identity inspection disagree." >&2
  exit 1
fi
run_mock_docker stop "$source_id"
if [ "$(run_mock_docker inspect -f '{{.State.Status}}' "$source_id")" != exited ]; then
  echo "[Error] Docker mock stop did not target the original container by ID." >&2
  exit 1
fi
run_mock_docker start "$source_id"
run_mock_docker rename "$source_id" renamed-by-id
if [ "$(run_mock_docker inspect -f '{{.State.Status}}' renamed-by-id)" != running ] ||
  [ "$(run_mock_docker inspect -f '{{.Id}}' renamed-by-id)" != "$source_id" ]; then
  echo "[Error] Docker mock start/rename did not preserve the original container by ID." >&2
  exit 1
fi
renamed_before="$(cat "${MOCK_RUNTIME_DIR}/renamed-by-id.meta")"
if run_mock_docker run -d --name renamed-by-id --label unrelated=true nginx:alpine; then
  echo "[Error] Docker mock run should reject an occupied name." >&2
  exit 1
fi
if [ "$(cat "${MOCK_RUNTIME_DIR}/renamed-by-id.meta")" != "$renamed_before" ]; then
  echo "[Error] Docker mock run overwrote an existing container on a name conflict." >&2
  exit 1
fi
run_mock_docker rm -f -v "$source_id"
if [ -e "${MOCK_RUNTIME_DIR}/renamed-by-id.meta" ] ||
  [ -n "$(run_mock_docker ps -a --no-trunc --filter "id=$source_id" --format '{{.ID}}')" ] ||
  [ "$(cat "${MOCK_RUNTIME_DIR}/busy-target.meta")" != "$busy_target_before" ]; then
  echo "[Error] Docker mock removal by ID should remove only that container." >&2
  exit 1
fi

proxy_id="$(run_mock_docker run -d --name nginx-proxy --memory 64m --read-only \
  --env NOTE=fixture nginx:alpine nginx -c /etc/nginx/dockistrate/nginx.conf)"
if [ "$(DOCKER_MOCK_INSPECT_STATUS=running run_mock_docker inspect -f '{{.Config.Image}}' "$proxy_id")" != nginx:alpine ]; then
  echo "[Error] Image inspection must read the saved image, not a forced status." >&2
  exit 1
fi
run_mock_docker stop "$proxy_id"
if [ "$(run_mock_docker inspect -f '{{.State.Status}}' "$proxy_id")" != exited ] ||
  [ "$(run_mock_docker inspect -f '{{.Config.Image}}' "$proxy_id")" != nginx:alpine ]; then
  echo "[Error] A stopped mock container must retain its actual state and image independently." >&2
  exit 1
fi
reload_marker="$TMP_ROOT/reload-failed"
DOCKER_MOCK_RELOAD_FAIL_ONCE_FILE="$reload_marker" run_mock_docker exec nginx-proxy nginx -t
if [ -e "$reload_marker" ]; then
  echo "[Error] Readiness checks must not consume the reload-only failure." >&2
  exit 1
fi
if DOCKER_MOCK_RELOAD_FAIL_ONCE_FILE="$reload_marker" run_mock_docker exec nginx-proxy nginx -s reload; then
  echo "[Error] The first reload must fail when its one-shot fault is enabled." >&2
  exit 1
fi
DOCKER_MOCK_RELOAD_FAIL_ONCE_FILE="$reload_marker" run_mock_docker exec nginx-proxy nginx -t
DOCKER_MOCK_RELOAD_FAIL_ONCE_FILE="$reload_marker" run_mock_docker exec nginx-proxy nginx -s reload
if DOCKER_MOCK_EXEC_FAIL=true DOCKER_MOCK_RELOAD_FAIL_ONCE_FILE="$reload_marker" run_mock_docker exec nginx-proxy nginx -t; then
  echo "[Error] The existing persistent exec failure must remain effective." >&2
  exit 1
fi

echo "Docker mock rename semantics checks passed."
