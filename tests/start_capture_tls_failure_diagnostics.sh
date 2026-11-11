#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${1:-}" = --probe ]; then
  # Load the real fixture and diagnostics without running its 43 capture cases.
  # The zero-case summary stays in the parent's private probe log.
  export CAPTURE_TLS_TEST_GROUP=diagnostics
  # shellcheck source=./start_capture_tls_launch_rollback.sh
  source "$ROOT_DIR/tests/start_capture_tls_launch_rollback.sh"
  CAPTURE_TEST_COMPLETED=false
  CASE_LABEL="forced diagnostic $2"
  printf '%s\n' 'synthetic command output is retained' >"$OUTPUT"
  printf '%s\n' 'synthetic audit output is retained' >"$AUDIT"
  : >"$EVENTS"
  case "$2" in
  success)
    status=0
    docker run >"$OUTPUT" 2>&1 || status=$?
    [ "$status" -eq 42 ]
    grep -Fxq capture-run "$EVENTS"
    CAPTURE_TEST_COMPLETED=true
    ;;
  missing-marker | marker-read-error)
    [ "$2" != marker-read-error ] || rm "$EVENTS"
    function start_capture() { printf '%s\n' 'synthetic command status 42'; return 42; }
    invoke_capture_failure
    ;;
  marker-write-error)
    EVENTS="$TEST_ROOT/event-directory"
    mkdir "$EVENTS"
    status=0
    docker run >"$OUTPUT" 2>&1 || status=$?
    printf 'observed mock status=%s\n' "$status"
    [ "$status" -eq 1 ] || exit 99
    exit "$status"
    ;;
  original-exit) exit 37 ;;
  unset-variable)
    unset UNSET_DIAGNOSTIC_VARIABLE
    # shellcheck disable=SC2154
    printf '%s\n' "$UNSET_DIAGNOSTIC_VARIABLE"
    ;;
  aborted-zero) exit 0 ;;
  term) kill -TERM "$$" ;;
  int) kill -INT "$$" ;;
  hup) kill -HUP "$$" ;;
  *) exit 98 ;;
  esac
  exit 0
fi

PROBE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_capture_diagnostics.XXXXXX")"
trap 'status=$?; if [ "$status" -eq 0 ]; then rm -rf "$PROBE_ROOT"; else printf "Diagnostic probe logs retained at %s\n" "$PROBE_ROOT" >&2; fi' EXIT
function fail() {
  printf '[Error] %s: %s\n' "$probe" "$*" >&2
  cat "$output" >&2
  exit 1
}

for probe in success missing-marker marker-read-error marker-write-error original-exit unset-variable aborted-zero term int hup; do
  case_dir="$PROBE_ROOT/$probe"
  mkdir "$case_dir"
  output="$PROBE_ROOT/$probe.log"
  status=0
  TMPDIR="$case_dir" "$BASH" "$ROOT_DIR/tests/start_capture_tls_failure_diagnostics.sh" --probe "$probe" >"$output" 2>&1 || status=$?
  expected=1
  case "$probe" in success) expected=0 ;; original-exit) expected=37 ;; term) expected=143 ;; int) expected=130 ;; hup) expected=129 ;; esac
  [ "$status" -eq "$expected" ] || fail "expected exit $expected, got $status"
  fixture_count=0
  retained=""
  for fixture in "$case_dir"/dockistrate_capture_launch_rollback.*; do
    [ -d "$fixture" ] || continue
    fixture_count=$((fixture_count + 1))
    retained="$fixture"
  done
  if [ "$probe" = success ]; then
    [ "$fixture_count" -eq 0 ] || fail 'successful fixture was not cleaned'
    continue
  fi
  [ "$fixture_count" -eq 1 ] || fail 'failed fixture was not retained'
  [ -f "$retained/output" ] && [ -f "$retained/audit" ] || fail 'retained fixture lost command or audit output'
  for message in 'fixture retained at' '[Diagnostics] captured command output:' '[Diagnostics] audit output:'; do
    grep -Fq "$message" "$output" || fail "missing diagnostic: $message"
  done
  case "$probe" in
  missing-marker) grep -Fq 'grep exit 1;' "$output" || fail 'missing marker status was lost' ;;
  marker-read-error) grep -Fq 'grep exit 2;' "$output" || fail 'marker read error was not distinguished' ;;
  marker-write-error)
    grep -Fq 'event write failed (exit 1): capture-run' "$output" || fail 'event write error was hidden'
    grep -Fq 'observed mock status=1' "$output" || fail 'event write status was replaced by mocked capture status'
    ;;
  esac
done
printf 'start-capture failure diagnostics: 10 cases passed.\n'
