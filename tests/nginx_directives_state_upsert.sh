#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/state"

DIRECTIVES_FILE="${STATE_DIR}/config/nginx_directives.csv"
TEST_DOMAIN="upsert-$$.test"

if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo "[Error] python3 (or python) is required for free-port selection" >&2
  exit 1
fi

pick_free_tcp_port() {
  "$PYTHON" - <<'PY'
import socket

s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

run_cmd() {
  (cd "$ROOT_DIR" && SKIP_DOCKER_CHECKS=true ./dockistrate.sh "$@")
}

if ! run_cmd set-nginx-directive global client_max_body_size 8m >/dev/null 2>&1; then
  echo "[Error] Initial global directive upsert failed." >&2
  exit 1
fi
if ! run_cmd set-nginx-directive global client_max_body_size 16m >/dev/null 2>&1; then
  echo "[Error] Global directive update failed." >&2
  exit 1
fi

row_count="$(awk -F',' 'NR>1 && $1=="global" && $6=="client_max_body_size" {c++} END {print c+0}' "$DIRECTIVES_FILE")"
if [ "$row_count" -ne 1 ]; then
  echo "[Error] Expected single upserted global row for client_max_body_size, got ${row_count}." >&2
  exit 1
fi

if ! grep -q '^global,,,,managed,client_max_body_size,16m$' "$DIRECTIVES_FILE"; then
  echo "[Error] Expected updated global directive value 16m after upsert." >&2
  exit 1
fi

LISTEN_PORT="$(pick_free_tcp_port)"

if ! run_cmd add-backend "$TEST_DOMAIN" nginx:alpine 18180 http --listen "$LISTEN_PORT" >/dev/null 2>&1; then
  echo "[Error] Failed to seed backend for scoped upsert test." >&2
  exit 1
fi

if ! run_cmd set-nginx-directive port "$TEST_DOMAIN" "$LISTEN_PORT" proxy_read_timeout 30s >/dev/null 2>&1; then
  echo "[Error] Initial port directive upsert failed." >&2
  exit 1
fi
if ! run_cmd set-nginx-directive port "$TEST_DOMAIN" "$LISTEN_PORT" proxy_read_timeout 45s >/dev/null 2>&1; then
  echo "[Error] Port directive update failed." >&2
  exit 1
fi

row_count="$(awk -F',' -v domain="$TEST_DOMAIN" -v listen_port="$LISTEN_PORT" 'NR>1 && $1=="port" && $2==domain && $3==listen_port && $6=="proxy_read_timeout" {c++} END {print c+0}' "$DIRECTIVES_FILE")"
if [ "$row_count" -ne 1 ]; then
  echo "[Error] Expected single upserted port row for proxy_read_timeout, got ${row_count}." >&2
  exit 1
fi

if ! grep -q "^port,${TEST_DOMAIN},${LISTEN_PORT},,managed,proxy_read_timeout,45s\$" "$DIRECTIVES_FILE"; then
  echo "[Error] Expected updated port directive value 45s after upsert." >&2
  exit 1
fi

echo "[tests] nginx_directives_state_upsert.sh: PASS"
