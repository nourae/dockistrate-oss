#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/state"

run_cmd() {
  (cd "$ROOT_DIR" && SKIP_DOCKER_CHECKS=true ./dockistrate.sh "$@")
}

if ! run_cmd set-nginx-directive global client_max_body_size 16m >/dev/null 2>&1; then
  echo "[Error] Expected typed directive set to succeed for valid size." >&2
  exit 1
fi

if ! list_output="$(run_cmd list-nginx-directives all 2>&1)"; then
  echo "[Error] Expected list-nginx-directives all to succeed." >&2
  exit 1
fi
if [[ "$list_output" != *"client_max_body_size"* ]]; then
  echo "[Error] Expected list-nginx-directives all output to include seeded directive." >&2
  exit 1
fi

if run_cmd list-nginx-directives all extra >/dev/null 2>&1; then
  echo "[Error] Expected list-nginx-directives all extra to fail." >&2
  exit 1
fi

if run_cmd set-nginx-directive global proxy_read_timeout not_a_time >/dev/null 2>&1; then
  echo "[Error] Expected typed directive set to fail for invalid time value." >&2
  exit 1
fi

if run_cmd set-nginx-directive global client_max_body_size "1m 2m" >/dev/null 2>&1; then
  echo "[Error] Expected typed directive set to fail for multi-token size value." >&2
  exit 1
fi

if run_cmd set-nginx-directive global proxy_read_timeout "30s 60s" >/dev/null 2>&1; then
  echo "[Error] Expected typed directive set to fail for multi-token time value." >&2
  exit 1
fi

if run_cmd set-nginx-directive-raw global 'bad-name!' ok >/dev/null 2>&1; then
  echo "[Error] Expected raw directive set to fail for invalid directive token." >&2
  exit 1
fi

if run_cmd set-nginx-directive-raw global custom_directive 'unsafe;' >/dev/null 2>&1; then
  echo "[Error] Expected raw directive set to fail for unsafe value containing ';'." >&2
  exit 1
fi

if run_cmd remove-all-nginx-directives all extra >/dev/null 2>&1; then
  echo "[Error] Expected remove-all-nginx-directives all extra to fail." >&2
  exit 1
fi

if ! run_cmd remove-all-nginx-directives all >/dev/null 2>&1; then
  echo "[Error] Expected remove-all-nginx-directives all to succeed." >&2
  exit 1
fi

if ! list_after_remove="$(run_cmd list-nginx-directives all 2>&1)"; then
  echo "[Error] Expected list-nginx-directives all to succeed after remove-all." >&2
  exit 1
fi
if [[ "$list_after_remove" != *"[None]"* ]]; then
  echo "[Error] Expected no directives after remove-all-nginx-directives all." >&2
  exit 1
fi

mkdir -p "$STATE_DIR/config"
cat >"$STATE_DIR/config/nginx_directives.csv" <<'EOF'
scope,domain,listen_port,path_prefix,directive_mode,directive_name,directive_value
global,,,,managed,not_in_catalog,1
EOF

if managed_catalog_miss_output="$(run_cmd update-nginx-config 2>&1)"; then
  echo "[Error] Expected update-nginx-config to fail for unknown managed directive." >&2
  exit 1
fi
if [[ "$managed_catalog_miss_output" != *"managed value failed catalog validation"* ]]; then
  echo "[Error] Expected managed catalog validation failure output for unknown managed directive." >&2
  exit 1
fi

echo "[tests] nginx_directives_validation.sh: PASS"
