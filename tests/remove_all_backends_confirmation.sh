#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backends/remove_all_backends.sh
source "$ROOT_DIR/lib/backends/remove_all_backends.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_bulk_confirmation.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
BACKEND_PORTS_FILE="$TMP_ROOT/backend_ports.csv"
INTERACTIVE=true
FAIL_DOMAIN=""

function seed_backends() {
  {
    printf '%s\n' "$STATE_BACKEND_PORTS_HEADER"
    # Inventory order and duplicate records must not affect confirmation order.
    state_backend_ports_row_backend beta.example.com 10.0.0.3:80 dockistrate-net
    state_backend_ports_row_backend alpha.example.com 10.0.0.2:80 dockistrate-net
    state_backend_ports_row_backend alpha.example.com 10.0.0.2:80 dockistrate-net
    state_backend_ports_row_port alpha.example.com 80 80 http none no off ""
  } >"$BACKEND_PORTS_FILE"
  : >"$TMP_ROOT/calls"
  : >"$TMP_ROOT/removed"
  : >"$TMP_ROOT/backups"
}

# Isolate destructive backend work while retaining the real confirmation reader,
# CSV parser, and existence check. A declined remove_backend returns success.
function remove_backend() {
  local domain="$1"
  printf '%s\n' "$domain" >>"$TMP_ROOT/calls"
  [ "$domain" != "$FAIL_DOMAIN" ] || return 1
  if ! confirm_prompt "Remove container for '${domain}'? (y/n): " yes_no auto_yes; then
    echo "[Info] Aborting."
    return 0
  fi
  awk -F, -v domain="$domain" 'NR == 1 || $2 != domain' \
    "$BACKEND_PORTS_FILE" >"$BACKEND_PORTS_FILE.next"
  mv "$BACKEND_PORTS_FILE.next" "$BACKEND_PORTS_FILE"
  printf '%s\n' "$domain" >>"$TMP_ROOT/removed"
}

function create_backup() {
  printf '%s\n' "$2" >>"$TMP_ROOT/backups"
}

function assert_file() {
  local file="$1" expected="$2"
  if [ "$(cat "$file")" != "$expected" ]; then
    printf '[Error] Unexpected contents of %s:\n' "$file" >&2
    cat "$file" >&2
    exit 1
  fi
}

function run_with_answers() {
  local answers="$1" remaining=""
  printf '%s' "$answers" >"$TMP_ROOT/answers"
  {
    remove_all_backends
    IFS= read -r remaining
    [ "$remaining" = sentinel ] || {
      echo "[Error] Bulk removal consumed the wrong confirmation input." >&2
      exit 1
    }
  } <"$TMP_ROOT/answers" >"$TMP_ROOT/output" 2>&1
}

expected_domains="$(printf '%s\n' alpha.example.com beta.example.com)"
seed_backends
run_with_answers $'yes\nyes\nsentinel\n'
assert_file "$TMP_ROOT/calls" "$expected_domains"
assert_file "$TMP_ROOT/removed" "$expected_domains"
assert_file "$TMP_ROOT/backups" RemoveAllBackends
grep -Fq '[Info] Removed 2 backends.' "$TMP_ROOT/output"
if backend_exists alpha.example.com || backend_exists beta.example.com; then
  echo '[Error] Approved backends were not both removed.' >&2
  exit 1
fi

seed_backends
run_with_answers $'no\nyes\nsentinel\n'
assert_file "$TMP_ROOT/calls" "$expected_domains"
assert_file "$TMP_ROOT/removed" beta.example.com
assert_file "$TMP_ROOT/backups" RemoveAllBackends
backend_exists alpha.example.com
if backend_exists beta.example.com; then
  echo '[Error] Approving the second backend did not remove it.' >&2
  exit 1
fi
grep -Fq '[Info] Removed 1 backends.' "$TMP_ROOT/output"

seed_backends
cp "$BACKEND_PORTS_FILE" "$TMP_ROOT/original.csv"
run_with_answers $'no\nno\nsentinel\n'
assert_file "$TMP_ROOT/removed" ""
assert_file "$TMP_ROOT/backups" ""
cmp -s "$BACKEND_PORTS_FILE" "$TMP_ROOT/original.csv"
grep -Fq '[Info] No backends removed.' "$TMP_ROOT/output"

# CLI mode keeps its existing automatic confirmation and leaves stdin alone.
seed_backends
INTERACTIVE=false
run_with_answers $'sentinel\n'
assert_file "$TMP_ROOT/removed" "$expected_domains"
assert_file "$TMP_ROOT/backups" RemoveAllBackends
INTERACTIVE=true

# Empty and absent inventories neither prompt nor create a backup.
seed_backends
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
run_with_answers $'sentinel\n'
assert_file "$TMP_ROOT/calls" ""
assert_file "$TMP_ROOT/backups" ""
grep -Fq '[Info] No backends configured.' "$TMP_ROOT/output"
rm "$BACKEND_PORTS_FILE"
run_with_answers $'sentinel\n'
assert_file "$TMP_ROOT/calls" ""
assert_file "$TMP_ROOT/backups" ""

# A failed backend removal still stops the batch before touching the next one.
seed_backends
FAIL_DOMAIN=alpha.example.com
if remove_all_backends < /dev/null >"$TMP_ROOT/output" 2>&1; then
  echo "[Error] Bulk removal swallowed a backend removal failure." >&2
  exit 1
fi
assert_file "$TMP_ROOT/calls" alpha.example.com
assert_file "$TMP_ROOT/removed" ""
assert_file "$TMP_ROOT/backups" ""
backend_exists alpha.example.com
backend_exists beta.example.com

echo '[tests] remove_all_backends_confirmation.sh: PASS'
