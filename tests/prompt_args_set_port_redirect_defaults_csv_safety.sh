#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/prompt_args_handlers_defaults.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_defaults.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_prompt_defaults_csv.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"

cat >"$BACKEND_PORTS_FILE" <<'EOF_BACKEND_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,quoted-defaults.test,127.0.0.1:9000,dockistrate-net,,,,,,,,,,,,,,,,,
port,quoted-defaults.test,,,,,80,9000,http,"custom/live/default,cert_80",no,on,302,off,auto,,,,,,
EOF_BACKEND_PORTS

PROMPT_ARGS_CONTEXT=("quoted-defaults.test" "80")
on_off_default="$(prompt_args_compute_default "set-port-redirect" "on_off" "off")"
code_default="$(prompt_args_compute_default "set-port-redirect" "code" "301")"

if [ "$on_off_default" != "on" ]; then
  echo "[Error] Expected on_off default to be 'on', got '${on_off_default}'." >&2
  exit 1
fi
if [ "$code_default" != "302" ]; then
  echo "[Error] Expected code default to be '302', got '${code_default}'." >&2
  exit 1
fi

echo "prompt_args set-port-redirect CSV-safe defaults check passed."
