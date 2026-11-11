#!/usr/bin/env bash
# Globals are consumed by the production state helpers.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/nginx_directives.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/path-directive-selectors.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"
CONFIG_DIR="$STATE_DIR/config"
TMP_DIR="$STATE_DIR/tmp"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'dedicated,inherited.example.com,example.com' \
  'dedicated,independent.example.com,example.com' \
  'dedicated,other-host.example.com,other.example.com' \
  'alias,alias.example.com,example.com' >"$BACKEND_ALIASES_FILE"

{
  printf '%s\n' "$STATE_NGINX_DIRECTIVES_HEADER"
  csv_join_row global '' '' '' managed send_timeout 70s
  csv_join_row stream-global '' '' '' managed proxy_timeout 71s
  for domain in example.com inherited.example.com independent.example.com other.example.com other-host.example.com; do
    csv_join_row backend "$domain" '' '' managed send_timeout 72s
    csv_join_row port "$domain" 38080 '' managed proxy_read_timeout 73s
    csv_join_row stream-backend "$domain" '' '' managed proxy_timeout 74s
    csv_join_row stream-port "$domain" 38090 '' managed proxy_timeout 75s
    csv_join_row path "$domain" 38080 /api managed proxy_read_timeout 11s
    csv_join_row path "$domain" 38080 '/api|assets' managed proxy_read_timeout 12s
    csv_join_row path "$domain" 38080 '/api|assets' raw proxy_set_header 'X-Trace "one,two"'
    csv_join_row path "$domain" 38080 '/(api|assets)' raw proxy_send_timeout 13s
    csv_join_row path "$domain" 38081 '/api|assets' raw proxy_send_timeout 14s
  done
} >"$TEST_WORK/original.csv"

function check_selector() {
  local domain="$1" port="$2" path="$3"
  cp "$TEST_WORK/original.csv" "$NGINX_DIRECTIVES_FILE"
  nginx_directives_state_remove_for_paths "$domain" "$port" "$path"
  python3 - "$TEST_WORK/original.csv" "$NGINX_DIRECTIVES_FILE" "$domain" "$port" "$path" <<'PY'
import csv, pathlib, sys
original, actual = [pathlib.Path(p) for p in sys.argv[1:3]]
domain, port, path = sys.argv[3:]
owner = {'inherited.example.com': 'example.com', 'independent.example.com': 'example.com',
         'other-host.example.com': 'other.example.com'}
with original.open(newline='') as f: before = list(csv.DictReader(f))
with actual.open(newline='') as f: after = list(csv.DictReader(f))
expected = [r for r in before if not (r['scope'] == 'path'
    and (not domain or owner.get(r['domain'], r['domain']) == domain.lower())
    and (not port or r['listen_port'] == port)
    and (not path or r['path_prefix'] == path))]
assert after == expected, 'Incorrect path directive selector: %r' % ((domain, port, path),)
PY
}

check_selector EXAMPLE.COM 38080 '/api|assets'
check_selector example.com 38080 '/(api|assets)'
check_selector example.com 38080 ''
check_selector example.com '' ''
check_selector other.example.com 38080 '/api|assets'
check_selector '' '' ''
printf '[PASS] Path directive selectors preserve literal boundaries, CSV values and unrelated scopes or owners\n'
