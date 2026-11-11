#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_commit_recovery.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
mkdir -p "$TEST_WORK/tests"
cp -R "$ROOT_DIR/tests/mocks" "$TEST_WORK/tests/"
export PATH="$TEST_WORK/tests/mocks:$PATH" SKIP_DOCKER_CHECKS=false
export DOCKER_MOCK_RUNTIME_DIR="$TEST_WORK/state/tmp/.docker_mock"
export DOCKER_MOCK_LOG_FILE="$TEST_WORK/docker.log"
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/recovery.example.com"
selected="${2:-all}"
if [ "$#" -gt 0 ] && { [ "$#" -ne 2 ] || [ "$1" != --case ]; }; then
  printf 'Usage: %s [--case before_proxy|after_proxy|before_commit|after_commit|metadata|commit]\n' "$0" >&2
  exit 2
fi
case "$selected" in all | before_proxy | after_proxy | before_commit | after_commit | metadata | commit) ;; *) exit 2 ;; esac

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function rename_fixture_function() {
  local path="$1" name="$2"
  sed "s/^function ${name}() {/function _test_original_${name}() {/" "$path" >"$TEST_WORK/renamed"
  mv "$TEST_WORK/renamed" "$path"
}
function assert_no_journal() {
  local journal=""
  for journal in "$TEST_WORK/state/runtime/transactions/"apply.*; do
    [ ! -d "$journal" ] || fail_test "Recovery retained a journal: $journal"
  done
}
function assert_previous_configuration() {
  local marker=""
  cmp -s "$TEST_WORK/baseline/domains/recovery.example.com/config/settings.csv" "$DOMAIN/config/settings.csv" || fail_test 'Recovery lost the previous editable settings'
  cmp -s "$TEST_WORK/baseline/domains/recovery.example.com/runtime/applied/settings.csv" "$DOMAIN/runtime/applied/settings.csv" || fail_test 'Recovery lost the previous accepted settings'
  cmp -s "$TEST_WORK/baseline/config/backend_http_versions.csv" "$TEST_WORK/state/config/backend_http_versions.csv" || fail_test 'Recovery lost the previous aggregate settings'
  cmp -s "$TEST_WORK/baseline/domains/recovery.example.com/generated/nginx/http.conf" "$DOMAIN/generated/nginx/http.conf" || fail_test 'Recovery lost the previous rendered domain'
  for marker in last_full_backup.txt last_full_backup.sha256; do
    if [ -f "$TEST_WORK/baseline/backups/$marker" ]; then
      cmp -s "$TEST_WORK/baseline/backups/$marker" "$TEST_WORK/state/backups/$marker" || fail_test 'Recovery left a provisional automatic backup marker'
    else
      [ ! -e "$TEST_WORK/state/backups/$marker" ] || fail_test 'Recovery created a previously absent automatic backup marker'
    fi
  done
}

# Use the production command, ownership checks, renderer and rollback hooks.
# Only Docker itself is the existing integration mock.
run_cli add-backend recovery.example.com nginx:alpine 8080 http --listen 18180
cp -Rp "$TEST_WORK/state" "$TEST_WORK/baseline"

cat >"$TEST_WORK/lib/domain_config/zz_crash_checkpoint.sh" <<'EOF'
# shellcheck shell=bash
function _test_crash_checkpoint() {
  [ "${DOCKISTRATE_TEST_CRASH_PHASE:-}" = "$1" ] || return 0
  printf '%s\n' "$1" >"$BASE_DIR/crash-reached"
  # PPID identifies this Bash process even on Bash 3. SIGKILL bypasses traps.
  sh -c 'kill -KILL "$PPID"'
  return 1
}
EOF
rename_fixture_function "$TEST_WORK/lib/backups/common.sh" _nginx_mark_runtime_rollback_needed
cat >>"$TEST_WORK/lib/backups/common.sh" <<'EOF'

function _nginx_mark_runtime_rollback_needed() {
  _test_crash_checkpoint before_proxy || return 1
  _test_original__nginx_mark_runtime_rollback_needed "$@"
}
EOF
rename_fixture_function "$TEST_WORK/lib/nginx/common.sh" reload_nginx_if_running
cat >>"$TEST_WORK/lib/nginx/common.sh" <<'EOF'

function reload_nginx_if_running() {
  _test_original_reload_nginx_if_running "$@" || return 1
  _test_crash_checkpoint after_proxy
}
EOF
rename_fixture_function "$TEST_WORK/lib/nginx/recreate_nginx_container.sh" recreate_nginx_container
cat >>"$TEST_WORK/lib/nginx/recreate_nginx_container.sh" <<'EOF'

function recreate_nginx_container() {
  _test_original_recreate_nginx_container "$@" || return 1
  _test_crash_checkpoint after_proxy
}
EOF
rename_fixture_function "$TEST_WORK/lib/domain_config/runtime_journal.sh" domain_config_runtime_commit
cat >>"$TEST_WORK/lib/domain_config/runtime_journal.sh" <<'EOF'

function domain_config_runtime_commit() {
  _test_crash_checkpoint before_commit || return 1
  _test_original_domain_config_runtime_commit "$@" || return 1
  _test_crash_checkpoint after_commit
}
EOF
rename_fixture_function "$TEST_WORK/lib/utils/fs.sh" finalize_temp_file
cat >>"$TEST_WORK/lib/utils/fs.sh" <<'EOF'

function finalize_temp_file() {
  if [ "${DOCKISTRATE_TEST_CRASH_PHASE:-}" = metadata ] && [ "$1" = "$LAST_POST_BACKUP_FILE" ]; then
    printf 'metadata\n' >"$BASE_DIR/crash-reached"
    return 1
  fi
  _test_original_finalize_temp_file "$@"
}
EOF

for phase in before_proxy after_proxy before_commit after_commit metadata; do
  case "$selected:$phase" in
  all:* | commit:before_commit | commit:after_commit | commit:metadata | "$phase:$phase") ;;
  *) continue ;;
  esac
  rm -rf "$TEST_WORK/state"
  cp -Rp "$TEST_WORK/baseline" "$TEST_WORK/state"
  rm -f "$TEST_WORK/crash-reached"
  provisional_backup=""
  : >"$DOCKER_MOCK_LOG_FILE"
  if DOCKISTRATE_TEST_CRASH_PHASE="$phase" "$BIN" set-backend-http-version recovery.example.com http1.0 >"$TEST_WORK/output" 2>&1; then
    fail_test "Injected $phase failure succeeded"
  fi
  [ "$(cat "$TEST_WORK/crash-reached" 2>/dev/null)" = "$phase" ] || fail_test "Did not reach $phase checkpoint"

  if [ "$phase" = metadata ]; then
    grep -Fq 'Rolled back.' "$TEST_WORK/output" || fail_test 'Metadata failure did not complete ordinary rollback'
  else
    journal=""
    for path in "$TEST_WORK/state/runtime/transactions/"apply.*; do
      [ ! -d "$path" ] || journal="$path"
    done
    [ -n "$journal" ] || fail_test 'SIGKILL did not retain its durable journal'
    expected_phase=active; [ "$phase" != after_commit ] || expected_phase=committed
    [ "$(test_csv_field "$journal/transaction.csv" phase)" = "$expected_phase" ] || fail_test 'Durable marker disagrees with the crash boundary'
    if [ "$phase" = before_commit ] || [ "$phase" = after_commit ]; then
      [ "$(test_csv_field "$journal/transaction.csv" auto_backup_requested)" = yes ] || fail_test 'Commit checkpoint did not include the deferred automatic backup'
      [ -f "$journal/automatic_backup/state.csv" ] || fail_test 'Automatic backup ownership was not journaled before commit'
      provisional_backup="$(test_csv_field "$journal/automatic_backup/state.csv" output)"
      [ -n "$provisional_backup" ] || fail_test 'Commit checkpoint preceded automatic backup publication'
    fi
    if [ "$phase" = before_proxy ]; then
      [ "$(test_csv_field "$journal/proxy.csv" apply_needed)" = false ] || fail_test 'Proxy was marked changed before its mutation boundary'
    else
      [ "$(test_csv_field "$journal/proxy.csv" apply_needed)" = true ] || fail_test 'Proxy activation intent was not durable'
    fi
    # A separate CLI process must recover with real Docker checks before the
    # new source-only initialization locally suppresses Docker operations.
    run_cli init-domain-config "${phase//_/-}.example.com" --kind certificate-only
  fi
  if [ "$phase" = after_commit ]; then
    [ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http1.0' ] || fail_test 'Recovery rolled back committed source'
    [ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http1.0' ] || fail_test 'Recovery rolled back committed accepted state'
    grep -qx 'recovery.example.com,http1.0' "$TEST_WORK/state/config/backend_http_versions.csv" || fail_test 'Recovery rolled back committed aggregate state'
    [ -e "$provisional_backup" ] || [ -e "$provisional_backup.tar.gz" ] || fail_test 'Recovery discarded the committed automatic backup'
  else
    assert_previous_configuration
    if [ -n "$provisional_backup" ]; then
      [ ! -e "$provisional_backup" ] && [ ! -e "$provisional_backup.tar.gz" ] && [ ! -e "$provisional_backup.tar.gz.sha256" ] || fail_test 'Recovery retained its uncommitted automatic backup output'
    fi
  fi
  [ "$(docker inspect -f '{{.State.Running}}' nginx-proxy)" = true ] || fail_test 'Recovery did not leave the managed proxy running'
  assert_no_journal
  printf '[PASS] domain runtime recovery at %s\n' "$phase"
done
