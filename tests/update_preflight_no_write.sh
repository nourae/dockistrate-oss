#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/state_sandbox.sh
source "$ROOT_DIR/tests/lib/state_sandbox.sh"

TMP_DIR=""

function cleanup() {
  if [ -n "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER:-false}" != "true" ]; then
    dockistrate_test_state_sandbox_restore
  fi
}
trap cleanup EXIT

if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER:-false}" != "true" ]; then
  dockistrate_test_state_sandbox "$ROOT_DIR"
fi

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function stat_field() {
  local path="${1:-}" gnu_fmt="${2:-}" bsd_fmt="${3:-}" value=""
  if value="$(stat -c "$gnu_fmt" "$path" 2>/dev/null)"; then
    printf '%s' "$value"
    return 0
  fi
  stat -f "$bsd_fmt" "$path"
}

function snapshot_state_tree() {
  local output="${1:-}" path="" rel="" type="" checksum=""

  : >"$output"
  [ -e "$ROOT_DIR/state" ] || return 0

  while IFS= read -r path; do
    rel="${path#$ROOT_DIR/state}"
    rel="${rel#/}"
    [ -n "$rel" ] || rel="."

    if [ -L "$path" ]; then
      type="symlink"
    elif [ -d "$path" ]; then
      type="dir"
    elif [ -f "$path" ]; then
      type="file"
    else
      type="other"
    fi

    checksum="-"
    if [ "$type" = "file" ]; then
      checksum="$(cksum <"$path")"
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$rel" \
      "$type" \
      "$(stat_field "$path" "%i" "%i")" \
      "$(stat_field "$path" "%a" "%Lp")" \
      "$(stat_field "$path" "%s" "%z")" \
      "$(stat_field "$path" "%Y" "%m")" \
      "$(stat_field "$path" "%Z" "%c")" \
      "$checksum" >>"$output"
  done < <(find "$ROOT_DIR/state" -print | sort)
}

function assert_snapshot_unchanged() {
  local before="${1:-}" after="${2:-}" label="${3:-command}"
  if ! cmp -s "$before" "$after"; then
    echo "[Error] State changed after ${label}." >&2
    diff -u "$before" "$after" >&2 || true
    exit 1
  fi
}

function run_absent_state_command() {
  rm -rf "$ROOT_DIR/state"
  "$@" >/dev/null 2>"$TMP_DIR/${1##*/}.err" || return "$?"
  [ ! -e "$ROOT_DIR/state" ] || fail_test "Absent state was created by: $*"
}

function run_existing_state_command() {
  local before="${TMP_DIR}/before.$$" after="${TMP_DIR}/after.$$"
  snapshot_state_tree "$before"
  "$@" >/dev/null 2>"$TMP_DIR/${1##*/}.err" || return "$?"
  snapshot_state_tree "$after"
  assert_snapshot_unchanged "$before" "$after" "$*"
}

function run_absent_state_command_expect_status() {
  local expected_status="${1:-0}" status=0
  shift
  rm -rf "$ROOT_DIR/state"
  set +e
  "$@" >/dev/null 2>"$TMP_DIR/${1##*/}.err"
  status=$?
  set -e
  [ "$status" -eq "$expected_status" ] || fail_test "Expected status ${expected_status} for '$*', got ${status}"
  [ ! -e "$ROOT_DIR/state" ] || fail_test "Absent state was created by: $*"
}

function run_existing_state_command_expect_status() {
  local expected_status="${1:-0}" before="${TMP_DIR}/before.$$" after="${TMP_DIR}/after.$$" status=0
  shift
  snapshot_state_tree "$before"
  set +e
  "$@" >/dev/null 2>"$TMP_DIR/${1##*/}.err"
  status=$?
  set -e
  [ "$status" -eq "$expected_status" ] || fail_test "Expected status ${expected_status} for '$*', got ${status}"
  snapshot_state_tree "$after"
  assert_snapshot_unchanged "$before" "$after" "$*"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-update-nowrite.XXXXXX")"

run_absent_state_command_expect_status 2 ./dockistrate.sh help
run_absent_state_command ./dockistrate.sh help-update || fail_test "help-update should succeed with absent state"
run_absent_state_command ./dockistrate.sh help update || fail_test "help update should succeed with absent state"
run_absent_state_command ./dockistrate.sh upgrade-preflight || fail_test "upgrade-preflight should succeed with absent state"
run_absent_state_command_expect_status 2 ./dockistrate.sh -v help
run_absent_state_command ./dockistrate.sh -v help-update || fail_test "-v help-update should succeed with absent state"
run_absent_state_command ./dockistrate.sh -v upgrade-preflight || fail_test "-v upgrade-preflight should succeed with absent state"

set +e
run_absent_state_command ./dockistrate.sh upgrade-preflight --require-backup
status=$?
set -e
[ "$status" -eq 5 ] || fail_test "--require-backup should fail with status 5 when state is absent, got ${status}"
[ ! -e "$ROOT_DIR/state" ] || fail_test "--require-backup created state while failing"

rm -rf "$ROOT_DIR/state"
mkdir -p "$ROOT_DIR/state/config" "$ROOT_DIR/state/backups/20260531_000000_Test" "$ROOT_DIR/state/logs"
printf '%s\n' "1" >"$ROOT_DIR/state/config/state_schema_version"
printf '%s\n' "preexisting audit" >"$ROOT_DIR/state/logs/audit.log"
printf '%s\n' "ignore" >"$ROOT_DIR/state/backups/.hidden"
printf '%s\n' "ignore" >"$ROOT_DIR/state/backups/partial.tar.gz.partial"
printf '%s\n' "backup" >"$ROOT_DIR/state/backups/20260531_000000_Test/README"

run_existing_state_command_expect_status 2 ./dockistrate.sh help
run_existing_state_command ./dockistrate.sh help-update || fail_test "help-update should not change existing state"
run_existing_state_command ./dockistrate.sh help update || fail_test "help update should not change existing state"
run_existing_state_command ./dockistrate.sh upgrade-preflight || fail_test "upgrade-preflight should not change existing state"
run_existing_state_command_expect_status 2 ./dockistrate.sh -v help
run_existing_state_command ./dockistrate.sh -v help-update || fail_test "-v help-update should not change existing state"
run_existing_state_command ./dockistrate.sh -v upgrade-preflight || fail_test "-v upgrade-preflight should not change existing state"

echo "[tests] update_preflight_no_write.sh: PASS"
