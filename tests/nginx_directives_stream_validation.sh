#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/state"

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

STREAM_LISTEN_PORT="$(pick_free_tcp_port)"
HTTP_LISTEN_PORT="$(pick_free_tcp_port)"
while [ "$HTTP_LISTEN_PORT" = "$STREAM_LISTEN_PORT" ]; do
  HTTP_LISTEN_PORT="$(pick_free_tcp_port)"
done

if ! run_cmd add-backend streamscope.test nginx:alpine 9000 tcp --listen "$STREAM_LISTEN_PORT" >/dev/null 2>&1; then
  echo "[Error] Expected add-backend to succeed for stream validation setup." >&2
  exit 1
fi

if ! run_cmd add-port streamscope.test "$HTTP_LISTEN_PORT" 9000 http none no >/dev/null 2>&1; then
  echo "[Error] Expected add-port to succeed for HTTP validation setup." >&2
  exit 1
fi

port_err=""
if port_err="$(run_cmd set-nginx-directive port streamscope.test "$STREAM_LISTEN_PORT" client_max_body_size 1m 2>&1)"; then
  echo "[Error] Expected HTTP scope 'port' to reject TCP mappings." >&2
  exit 1
fi
if [[ "$port_err" != *"Use scope 'stream-port'"* ]]; then
  echo "[Error] Expected TCP guidance to suggest scope 'stream-port'." >&2
  exit 1
fi

if ! run_cmd set-nginx-directive stream-port streamscope.test "$STREAM_LISTEN_PORT" proxy_timeout 33s >/dev/null 2>&1; then
  echo "[Error] Expected stream-port directive write to succeed on TCP mapping." >&2
  exit 1
fi

if run_cmd set-nginx-directive stream-port streamscope.test "$HTTP_LISTEN_PORT" proxy_timeout 44s >/dev/null 2>&1; then
  echo "[Error] Expected stream-port to reject non-TCP mappings." >&2
  exit 1
fi

if ! run_cmd set-nginx-directive stream-backend streamscope.test proxy_connect_timeout 12s >/dev/null 2>&1; then
  echo "[Error] Expected stream-backend directive write to succeed for backend domain." >&2
  exit 1
fi

if ! run_cmd add-dedicated-host admin.streamscope.test streamscope.test >/dev/null 2>&1; then
  echo "[Error] Expected dedicated host creation to succeed for scope validation." >&2
  exit 1
fi

if run_cmd set-nginx-directive stream-backend admin.streamscope.test proxy_connect_timeout 10s >/dev/null 2>&1; then
  echo "[Error] Expected stream-backend to reject dedicated-host domain targets." >&2
  exit 1
fi

if ! run_cmd set-nginx-directive stream-port streamscope.test "$STREAM_LISTEN_PORT" ssl_preread on >/dev/null 2>&1; then
  echo "[Error] Expected module-gated ssl_preread directive to be accepted when capability checks are skipped." >&2
  exit 1
fi

if ! stream_list="$(run_cmd list-nginx-directives stream-port streamscope.test "$STREAM_LISTEN_PORT" 2>&1)"; then
  echo "[Error] Expected stream-port directive listing to succeed." >&2
  exit 1
fi
if [[ "$stream_list" != *"proxy_timeout"* ]] || [[ "$stream_list" != *"ssl_preread"* ]]; then
  echo "[Error] Expected stream-port listing to include seeded stream directives." >&2
  exit 1
fi

echo "[tests] nginx_directives_stream_validation.sh: PASS"
