#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_certbot_ownership.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Source function definitions only; do not start the integration suite.
# shellcheck source=integration/test_cli.d/test_certbot_darwin_user_mapping.sh
source "${CERTBOT_FIXTURE_SOURCE:-$ROOT_DIR/tests/integration/test_cli.d/test_certbot_darwin_user_mapping.sh}"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

# Exercise the real assertion wrapper without loading shunit2's autorunner.
# Command-form support permits a meaningful negative control with the old helper.
function assertTrue() {
  case "$2" in
  0) return 0 ;;
  [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) return "$2" ;;
  *) "$BASH" -c "$2" ;;
  esac
}

SUDO_USER=""
export SUDO_USER
LOG_DIR="$TMP_ROOT/state/logs"
TRACE="$TMP_ROOT/docker.log"
STUB_DIR="$TMP_ROOT/bin"
EXPECTED_OWNER="$(/usr/bin/id -un):$(/usr/bin/id -gn)"
CASE_COUNT=0
_write_certbot_darwin_stubs "$STUB_DIR"

function reset_trace() {
  : >"$TRACE"
  rm -f "${TRACE}.chown-argv"
}

function record_chown() {
  CHOWN_MOCK_LOG_FILE="$TRACE" "$BASH" "$STUB_DIR/chown" "$@"
}

function expect_allowed() {
  local label="$1"
  if ! _assert_certbot_no_mount_ownership_mutation "$TRACE" "$label"; then
    fail_test "Expected permitted log repair: $label"
  fi
  CASE_COUNT=$((CASE_COUNT + 1))
}

function expect_rejected() {
  local label="$1"
  if _assert_certbot_no_mount_ownership_mutation "$TRACE" "$label"; then
    fail_test "Unexpected ownership call escaped the assertion: $label"
  fi
  CASE_COUNT=$((CASE_COUNT + 1))
}

# This failed under the old grep assertion when a root CLI command logged.
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log"
expect_allowed 'audit log repair'
grep -q '^chown ' "$TRACE" || fail_test 'Original human-readable trace was lost'
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/docker_manager.log"
expect_allowed 'audit and manager log repairs'

reset_trace
printf 'subcommand=run certbot/certbot\n' >"$TRACE"
expect_allowed 'no ownership operations'

for target in "$TMP_ROOT/state/certs/letsencrypt" "$TMP_ROOT/state/acme-webroot" \
  "$TMP_ROOT/state/certs/letsencrypt/archive/example.test/privkey1.pem"; do
  reset_trace
  record_chown "$EXPECTED_OWNER" "$target"
  expect_rejected 'Certbot mount or private key'
done

reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log" "$TMP_ROOT/state/certs/letsencrypt"
expect_rejected 'allowed log targets plus an extra Certbot target'
reset_trace
record_chown -R "$EXPECTED_OWNER" "$TMP_ROOT/state"
expect_rejected 'recursive ancestor ownership'
reset_trace
record_chown "${EXPECTED_OWNER}-unexpected" "$LOG_DIR" "$LOG_DIR/audit.log"
expect_rejected 'unexpected owner for a log repair'
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR-other" "$LOG_DIR/audit.log"
expect_rejected 'log directory prefix collision'
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log.other"
expect_rejected 'log filename prefix collision'
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR/audit.log" "$LOG_DIR"
expect_rejected 'reordered targets'
reset_trace
record_chown -- "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log"
expect_rejected 'additional option'
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log"
record_chown "$EXPECTED_OWNER" "$TMP_ROOT/state/acme-webroot"
expect_rejected 'mount mutation after a permitted repair'

# NUL-delimited argv must distinguish one path from two even with shell syntax,
# whitespace, quotes, newlines, and a trailing backslash in the fixture root.
LOG_DIR="$TMP_ROOT/log path ' \" \$(literal)
line\\"
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log"
expect_allowed 'exact log targets containing shell syntax and newlines'
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR $LOG_DIR/audit.log"
expect_rejected 'one combined argument resembling two log targets'
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log
chown $EXPECTED_OWNER $TMP_ROOT/state/certs/letsencrypt"
expect_rejected 'newline in an unexpected target'

reset_trace
printf 'chown root:root unrecorded-target\n' >"$TRACE"
expect_rejected 'human-readable ownership call without argv record'
reset_trace
record_chown "$EXPECTED_OWNER" "$LOG_DIR" "$LOG_DIR/audit.log"
printf '3' >>"${TRACE}.chown-argv"
expect_rejected 'truncated next record count'
reset_trace
printf '%s\0' 3 "$EXPECTED_OWNER" "$LOG_DIR" >"${TRACE}.chown-argv"
expect_rejected 'truncated argv record'
reset_trace
printf '%s\0' invalid >"${TRACE}.chown-argv"
expect_rejected 'invalid record count'

printf '[tests] PASS: Certbot ownership trace (%s cases)\n' "$CASE_COUNT"
