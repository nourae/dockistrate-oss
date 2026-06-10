#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-update-standalone-cleanup.XXXXXX")"
WORK_ROOT="${TMP_ROOT}/repo"

function cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function copy_standalone_fixture() {
  mkdir -p \
    "$WORK_ROOT/tests/lib" \
    "$WORK_ROOT/lib/cli" \
    "$WORK_ROOT/lib/config"

  cp "$ROOT_DIR/tests/update_preflight_no_write.sh" "$WORK_ROOT/tests/update_preflight_no_write.sh"
  cp "$ROOT_DIR/tests/update_preflight_schema_tags.sh" "$WORK_ROOT/tests/update_preflight_schema_tags.sh"
  cp "$ROOT_DIR/tests/lib/state_sandbox.sh" "$WORK_ROOT/tests/lib/state_sandbox.sh"
  cp "$ROOT_DIR/lib/config.sh" "$WORK_ROOT/lib/config.sh"
  cp "$ROOT_DIR/lib/runtime_paths.sh" "$WORK_ROOT/lib/runtime_paths.sh"
  cp "$ROOT_DIR/lib/config/"*.sh "$WORK_ROOT/lib/config/"
  cp "$ROOT_DIR/lib/cli/upgrade_preflight.sh" "$WORK_ROOT/lib/cli/upgrade_preflight.sh"
}

function run_cleanup_case() {
  local script="${1:-}" label="${2:-}" status=0
  local sentinel="${WORK_ROOT}/state/config/standalone-cleanup-sentinel.txt"
  local missing_tmp="${TMP_ROOT}/missing-tmp"

  rm -rf "$WORK_ROOT/state" "$WORK_ROOT/tmp" "$missing_tmp"
  mkdir -p "$WORK_ROOT/state/config"
  printf '%s\n' "$label" >"$sentinel"

  set +e
  (
    unset DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER
    export TMPDIR="$missing_tmp"
    /bin/bash "$WORK_ROOT/$script"
  ) >"$TMP_ROOT/${label}.out" 2>"$TMP_ROOT/${label}.err"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail_test "${script} should fail when TMPDIR is unavailable"
  if [ "$(cat "$sentinel" 2>/dev/null || true)" != "$label" ]; then
    echo "[stderr]" >&2
    cat "$TMP_ROOT/${label}.err" >&2 || true
    fail_test "${script} did not restore state after early standalone failure"
  fi
  if [ -d "$WORK_ROOT/tmp" ] &&
    find "$WORK_ROOT/tmp" -path "*/state/config/standalone-cleanup-sentinel.txt" -print | grep -q .; then
    fail_test "${script} left the original state in a sandbox snapshot"
  fi
}

copy_standalone_fixture
run_cleanup_case "tests/update_preflight_no_write.sh" "no-write"
run_cleanup_case "tests/update_preflight_schema_tags.sh" "schema-tags"

echo "[tests] update_preflight_standalone_cleanup.sh: PASS"
