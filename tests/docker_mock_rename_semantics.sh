#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_docker_mock_rename.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_RUNTIME_DIR="${TMP_ROOT}/runtime"
mkdir -p "$MOCK_RUNTIME_DIR"

function run_mock_docker() {
  DOCKER_MOCK_RUNTIME_DIR="$MOCK_RUNTIME_DIR" bash "$ROOT_DIR/tests/mocks/docker" "$@"
}

printf 'status=running\nlabels=\nmounts=\n' >"${MOCK_RUNTIME_DIR}/source.meta"
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

echo "Docker mock rename semantics checks passed."
