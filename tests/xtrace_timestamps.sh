#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-xtrace-time.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../lib/utils/runtime.sh
source "$ROOT_DIR/lib/utils/runtime.sh"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

mkdir "$TEST_DIR/bin"
DATE_CALLS_FILE="$TEST_DIR/date-calls"
export DATE_CALLS_FILE
cat >"$TEST_DIR/bin/date" <<'DATE_STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'date\n' >>"$DATE_CALLS_FILE"
printf '2026-10-17 12:34:56 +0000\n'
DATE_STUB
chmod 755 "$TEST_DIR/bin/date"

# Test real xtrace expansion over many builtin commands instead of using a
# machine-speed threshold. Session initialization may call date once; trace
# prefixes themselves must never launch it. Logging can be disabled without
# removing the session's wall-clock anchor from the trace destination.
(
  PATH="$TEST_DIR/bin:$PATH"
  ENABLE_LOGGING=false
  SECONDS=1700
  xtrace_start
  case "$-" in *x*) ;; *) fail_test 'xtrace_start did not enable tracing' ;; esac
  [ "$SECONDS" -ge 1700 ] || fail_test 'trace initialization reset caller SECONDS'
  [ "$DOCKISTRATE_TRACE_START_SECONDS" -ge 1700 ] || fail_test 'trace origin did not use caller SECONDS'
  : DUMMY_FULL_TRACE_VALUE
  for ((statement = 0; statement < 250; statement++)); do
    : "trace statement $statement"
  done
  (
    : NESTED_TRACE_VALUE
  )
  # Advance the builtin clock deterministically without a sleep or external
  # clock call, then verify that PS4 expands its current value on every line.
  SECONDS=$((DOCKISTRATE_TRACE_START_SECONDS + 7))
  : SHIFTED_TRACE_VALUE
  set +x
) 2>"$TEST_DIR/trace.log"

date_calls="$(wc -l <"$DATE_CALLS_FILE")"
[ "$date_calls" -eq 1 ] || fail_test "expected one date call for the session, got $date_calls"
grep -Fq '2026-10-17 12:34:56 +0000' "$TEST_DIR/trace.log" || fail_test 'trace lost its wall-clock anchor'
grep -Eq '\[session=[0-9]+ elapsed=[0-9]+s\] \[CMD\]' "$TEST_DIR/trace.log" || fail_test 'trace lost session/elapsed/CMD context'
shifted_offset="$(sed -n 's/^.* elapsed=\([0-9][0-9]*\)s] \[CMD\] : SHIFTED_TRACE_VALUE$/\1/p' "$TEST_DIR/trace.log")"
case "$shifted_offset" in
'' | *[!0-9]*) fail_test 'trace omitted a valid shifted elapsed offset' ;;
esac
[ "$shifted_offset" -ge 7 ] || fail_test 'trace elapsed offset did not advance'
for expected in DUMMY_FULL_TRACE_VALUE NESTED_TRACE_VALUE 'trace statement 249'; do
  grep -Fq "$expected" "$TEST_DIR/trace.log" || fail_test "trace omitted $expected"
done

echo '[tests] xtrace_timestamps.sh: PASS'
