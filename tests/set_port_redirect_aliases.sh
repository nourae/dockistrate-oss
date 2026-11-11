#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/utils/fs.sh
source "$ROOT_DIR/lib/utils/fs.sh"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/ports/set_port_redirect.sh
source "$ROOT_DIR/lib/ports/set_port_redirect.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-port-redirect-aliases.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
{
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER"
  state_backend_ports_row_backend "redirect-alias.test" "127.0.0.1:8080" "dockistrate-net"
  state_backend_ports_row_port "redirect-alias.test" "80" "8080" "http" "" "no" "on" "301"
} >"$BACKEND_PORTS_FILE"

function resolve_backend_domain() {
  local output_var="${1:-}" input_domain="${2:-}"
  printf -v "$output_var" '%s' "$input_domain"
}

function backend_exists() {
  return 0
}

function _config_begin_transaction_if_needed() {
  local output_var="${1:-}"
  printf -v "$output_var" '%s' "false"
}

function _config_end_transaction_if_started() {
  return 0
}

function create_backup() {
  return 0
}

function update_nginx_config() {
  return 0
}

function assert_redirect_state() {
  local expected_flag="${1:-}" expected_code="${2:-}"
  local line="" line_no=0 found="no"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line"
    if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
      [ "$STATE_BP_DOMAIN" = "redirect-alias.test" ] &&
      [ "$STATE_BP_LISTEN_PORT" = "80" ]; then
      found="yes"
      if [ "$STATE_BP_REDIRECT_FLAG" != "$expected_flag" ]; then
        echo "[Error] Expected redirect flag '$expected_flag', got '$STATE_BP_REDIRECT_FLAG'." >&2
        exit 1
      fi
      if [ "$STATE_BP_REDIRECT_CODE" != "$expected_code" ]; then
        echo "[Error] Expected redirect code '$expected_code', got '$STATE_BP_REDIRECT_CODE'." >&2
        exit 1
      fi
    fi
  done <"$BACKEND_PORTS_FILE"

  if [ "$found" != "yes" ]; then
    echo "[Error] Redirect test port mapping was not found." >&2
    exit 1
  fi
}

set_port_redirect "redirect-alias.test" "80" "no" "308" >/dev/null
assert_redirect_state "off" ""

set_port_redirect "redirect-alias.test" "80" "yes" "302" >/dev/null
assert_redirect_state "on" "302"

__dockistrate_completion_handlers=()
# shellcheck source=../completion/commands/_dockistrate_complete_port_redirect_options.sh
source "$ROOT_DIR/completion/commands/_dockistrate_complete_port_redirect_options.sh"

cur=""
prev="80"
cword=4
words=(dockistrate.sh set-port-redirect redirect-alias.test 80)
COMPREPLY=()
if ! _dockistrate_complete_port_redirect_options set-port-redirect; then
  echo "[Error] set-port-redirect completion handler did not handle the redirect flag." >&2
  exit 1
fi
if [ "${COMPREPLY[*]-}" != "on off" ]; then
  echo "[Error] Expected canonical redirect completion values 'on off', got '${COMPREPLY[*]-}'." >&2
  exit 1
fi

echo "[tests] set_port_redirect_aliases.sh: PASS"
