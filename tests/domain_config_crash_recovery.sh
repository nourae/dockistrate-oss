#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_recovery.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }; }
function install_crash() {
  cat >"$TEST_WORK/lib/domain_config/zz_crash_after_source.sh" <<'EOF'
# shellcheck shell=bash
function _domain_config_publish_applied() {
  # A child process identifies the current Bash process portably, including
  # Bash 3 where BASHPID is unavailable. SIGKILL bypasses every rollback trap.
  sh -c 'kill -KILL "$PPID"'
  return 1
}
EOF
}
function assert_no_journal() {
  local journal=""
  for journal in "$TEST_WORK/state/runtime/transactions/"apply.*; do
    [ ! -d "$journal" ] || fail_test 'recovery left an unfinished journal'
  done
}

run_cli init-domain-config example.com
test_domain_csv_set "$DOMAIN/config/backend.csv" image nginx:alpine
run_cli apply-domain-config example.com
run_cli set-backend-http-version example.com http1.1

install_crash
if "$BIN" set-backend-http-version example.com http1.0 >"$TEST_WORK/output" 2>&1; then fail_test 'SIGKILL injection succeeded'; fi
rm "$TEST_WORK/lib/domain_config/zz_crash_after_source.sh"
[ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http1.0' ] || fail_test 'crash did not leave published source for recovery'
[ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http1.1' ] || fail_test 'crash advanced accepted snapshot'
run_cli set-backend-http-version example.com http2
[ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http2' ] || fail_test 'next command did not recover before checking pending edits'
assert_no_journal

# An operator edit made after the interrupted publication remains a draft.
install_crash
if "$BIN" set-backend-http-version example.com http1.0 >"$TEST_WORK/output" 2>&1; then fail_test 'second SIGKILL injection succeeded'; fi
rm "$TEST_WORK/lib/domain_config/zz_crash_after_source.sh"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.1,,,,,\n' >"$DOMAIN/config/settings.csv"
if "$BIN" set-backend-http-version example.com http1.0 >"$TEST_WORK/output" 2>&1; then fail_test 'recovery overwrote an operator edit'; fi
[ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http1.1' ] || fail_test 'recovery lost newer source edit'
[ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http2' ] || fail_test 'recovery failed to restore accepted snapshot'
run_cli apply-domain-config example.com
[ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http1.1' ] || fail_test 'retained draft could not be applied'
assert_no_journal
printf '[PASS] domain configuration crash recovery\n'
