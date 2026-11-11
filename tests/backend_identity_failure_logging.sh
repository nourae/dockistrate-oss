#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/test_cli.d/test_backend_container_identity.sh
source "$ROOT_DIR/tests/integration/test_cli.d/test_backend_container_identity.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_identity_logging.XXXXXX")"
RETAINED_PATHS="$TEST_ROOT/retained-paths"
: >"$RETAINED_PATHS"

function cleanup() {
  local artifact
  while IFS= read -r artifact; do
    case "$artifact" in
      /tmp/dockistrate_identity_failure.*) rm -rf "$artifact" ;;
    esac
  done <"$RETAINED_PATHS"
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

function fail() {
  printf '[Error] backend identity failure logging: %s\n' "$*" >&2
  exit 1
}

# The original integration case keeps its assertions. These stubs record their
# actual results so a diagnostic helper returning zero cannot hide a failure.
function assertEquals() {
  if [ "$2" != "$3" ]; then
    ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
    printf '%s: expected=%s actual=%s\n' "$1" "$2" "$3" >>"$ASSERTION_LOG"
    return 1
  fi
}

function assertNotEquals() {
  if [ "$2" = "$3" ]; then
    ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
    printf '%s: unexpectedly equal=%s\n' "$1" "$3" >>"$ASSERTION_LOG"
    return 1
  fi
}

function run_dockistrate() {
  local command="$1" domain="${2:-}" refresh_count=0
  case "$command" in
    add-backend)
      printf 'backend,%s,fixture-endpoint,fixture-network\n' "$domain" >>"$CONFIG_DIR/backend_ports.csv"
      ;;
    update-backend)
      if [ "$domain" = identity-second.test ] && [ "$FAIL_STAGE" = second ]; then
        printf 'injected second migration stdout\n'
        printf 'injected second migration stderr\n' >&2
        return 73
      fi
      ;;
    update-nginx-config)
      if [ -f "$STATE_DIR/refresh-count" ]; then
        refresh_count="$(cat "$STATE_DIR/refresh-count")"
      fi
      refresh_count=$((refresh_count + 1))
      printf '%s\n' "$refresh_count" >"$STATE_DIR/refresh-count"
      if [ "$refresh_count" -eq 1 ]; then
        if [ "$FAIL_STAGE" = rejection ]; then
          printf 'injected unexpected middle refresh success\n'
          return 0
        fi
        printf 'expected remaining legacy backend refusal\n'
        return 1
      fi
      if [ "$FAIL_STAGE" = final ]; then
        printf 'injected final refresh failure\n'
        return 74
      fi
      ;;
    *) fail "unexpected stub command: $command" ;;
  esac
  return 0
}

MOCK_BIN_DIR="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN_DIR"
cat >"$MOCK_BIN_DIR/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%064d\n' 1
MOCK
chmod 700 "$MOCK_BIN_DIR/docker"

function run_case() {
  FAIL_STAGE="$1"
  STATE_DIR="$TEST_ROOT/$FAIL_STAGE/state"
  CONFIG_DIR="$STATE_DIR/config"
  CASE_LOG="$TEST_ROOT/$FAIL_STAGE/case.log"
  ASSERTION_LOG="$TEST_ROOT/$FAIL_STAGE/assertions.log"
  ASSERTION_FAILURES=0
  mkdir -p "$CONFIG_DIR" "$STATE_DIR/logs" "$STATE_DIR/tmp/.docker_mock"
  printf 'fixture diagnostic log\n' >"$STATE_DIR/logs/dockistrate.log"
  printf 'fixture mock container state\n' >"$STATE_DIR/tmp/.docker_mock/container"
  : >"$CONFIG_DIR/backend_ports.csv"
  : >"$ASSERTION_LOG"
  if test_update_backend_explicit_legacy_replacement_preserves_other_legacy_rows >"$CASE_LOG" 2>&1; then
    CASE_STATUS=0
  else
    CASE_STATUS=$?
  fi
  sed -n 's/^\[tests\] Failure artifacts: //p' "$CASE_LOG" >>"$RETAINED_PATHS"
}

function verify_retained_failure() {
  local stage="$1" status="$2" output_fragment="$3" artifact
  artifact="$(sed -n 's/^\[tests\] Failure artifacts: //p' "$CASE_LOG")"
  case "$artifact" in
    /tmp/dockistrate_identity_failure.*) ;;
    *) fail "missing single retained artifact directory for $stage" ;;
  esac
  [ -d "$artifact" ] || fail "artifact directory does not exist for $stage"
  [ "$(LC_ALL=C ls -ld "$artifact" | cut -c 1-10)" = drwx------ ] || fail 'artifact directory is not private'
  grep -Fxq "stage=$stage" "$artifact/result.txt" || fail 'recorded failure stage differs'
  grep -Fxq "status=$status" "$artifact/result.txt" || fail 'recorded original command status differs'
  grep -Fq "$output_fragment" "$artifact/command-output.log" || fail 'command output was overwritten'
  grep -Fq "$output_fragment" "$CASE_LOG" || fail 'failure output was not printed'
  grep -Fq "stage=$stage status=$status" "$CASE_LOG" || fail 'failure stage/status was not printed'
  cmp "$CONFIG_DIR/backend_ports.csv" "$artifact/config/backend_ports.csv" || fail 'retained config differs'
  cmp "$STATE_DIR/logs/dockistrate.log" "$artifact/logs/dockistrate.log" || fail 'retained log differs'
  cmp "$STATE_DIR/tmp/.docker_mock/container" "$artifact/.docker_mock/container" || fail 'retained mock state differs'
  [ -s "$artifact/filesystem.log" ] || fail 'filesystem diagnostics missing'
  rm -rf "$STATE_DIR"
  [ -f "$artifact/config/backend_ports.csv" ] && [ -f "$artifact/.docker_mock/container" ] ||
    fail 'fixture teardown removed failure evidence'
}

function case_success_is_quiet() {
  run_case success
  [ "$CASE_STATUS" -eq 0 ] && [ "$ASSERTION_FAILURES" -eq 0 ] || fail 'successful case changed result'
  [ ! -s "$CASE_LOG" ] || fail 'successful case produced failure diagnostics'
  [ ! -s "$RETAINED_PATHS" ] || fail 'successful case retained failure artifacts'
}

function case_second_migration_status_and_output_survive() {
  run_case second
  [ "$CASE_STATUS" -eq 0 ] && [ "$ASSERTION_FAILURES" -eq 1 ] || fail 'second migration assertion result changed'
  grep -Fq 'second explicit migration succeeds: expected=0 actual=73' "$ASSERTION_LOG" || fail 'second migration assertion lost exit 73'
  verify_retained_failure migrate-second 73 'injected second migration stdout'
  grep -Fq 'injected second migration stderr' "$CASE_LOG" || fail 'second migration stderr lost'
}

function case_final_refresh_preserves_failed_return() {
  run_case final
  [ "$CASE_STATUS" -eq 1 ] && [ "$ASSERTION_FAILURES" -eq 1 ] || fail 'final assertion return changed'
  grep -Fq 'ordinary refresh succeeds after all legacy backends are verified: expected=0 actual=74' "$ASSERTION_LOG" || fail 'final assertion lost exit 74'
  verify_retained_failure refresh-after-migration 74 'injected final refresh failure'
}

function case_middle_refresh_still_requires_rejection() {
  run_case rejection
  [ "$CASE_STATUS" -eq 0 ] && [ "$ASSERTION_FAILURES" -eq 1 ] || fail 'middle rejection assertion changed'
  grep -Fq 'ordinary refresh still refuses the remaining legacy backend: unexpectedly equal=0' "$ASSERTION_LOG" || fail 'unexpected middle success was hidden'
  verify_retained_failure reject-remaining-legacy 0 'injected unexpected middle refresh success'
}

function case_retention_errors_do_not_hide_original_failure() {
  local artifact
  function mktemp() {
    local directory
    directory="$(command mktemp "$@")" || return $?
    mkdir "$directory/result.txt" "$directory/command-output.log"
    printf '%s\n' "$directory"
  }
  function cp() {
    printf 'injected artifact copy failure\n' >&2
    return 81
  }
  run_case second
  unset -f mktemp cp
  [ "$CASE_STATUS" -eq 0 ] && [ "$ASSERTION_FAILURES" -eq 1 ] || fail 'artifact errors changed the original assertion'
  grep -Fq 'second explicit migration succeeds: expected=0 actual=73' "$ASSERTION_LOG" || fail 'artifact errors hid exit 73'
  grep -Fq 'stage=migrate-second status=73' "$CASE_LOG" || fail 'artifact errors hid the original stage/status'
  grep -Fq 'injected second migration stderr' "$CASE_LOG" || fail 'artifact errors hid the original output'
  grep -Fq 'Could not retain the failure result.' "$CASE_LOG" || fail 'result write error was hidden'
  grep -Fq 'Could not retain command output.' "$CASE_LOG" || fail 'output write error was hidden'
  grep -Fq 'Could not fully retain fixture path:' "$CASE_LOG" || fail 'snapshot copy error was hidden'
  artifact="$(sed -n 's/^\[tests\] Failure artifacts: //p' "$CASE_LOG")"
  [ -d "$artifact" ] || fail 'partial artifact location was not printed'
}

cases=(
  case_success_is_quiet
  case_second_migration_status_and_output_survive
  case_final_refresh_preserves_failed_return
  case_middle_refresh_still_requires_rejection
  case_retention_errors_do_not_hide_original_failure
)
for case_name in "${cases[@]}"; do
  "$case_name"
  printf '[tests] backend-identity-logging PASS: %s\n' "$case_name"
done
printf '[tests] Backend identity failure logging tests passed (%s cases).\n' "${#cases[@]}"
