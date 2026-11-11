#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Each case continues in the same shell after the failed command. The parent
# then verifies that shell exit cannot replay a stale certificate transaction.
if [ "$#" -eq 0 ]; then
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_certbot_pull.XXXXXX")"
  trap 'rm -rf "$TMP_ROOT"' EXIT
  for test_case in conditional interactive nested; do
    case_dir="$TMP_ROOT/$test_case"
    mkdir -p "$case_dir"
    if ! "$BASH" "${BASH_SOURCE[0]}" "$test_case" "$case_dir"; then
      printf '[Error] Certbot pull transaction case failed: %s\n' "$test_case" >&2
      exit 1
    fi
    if ! grep -qx later-operation "$case_dir/state/config/marker"; then
      printf '[Error] Shell exit reverted the later operation: %s\n' "$test_case" >&2
      exit 1
    fi
    printf '[tests] PASS: Certbot pull failure %s\n' "$test_case"
  done
  exit 0
fi

[ "$#" -eq 2 ] || exit 2
TEST_CASE="$1"
case "$TEST_CASE" in conditional | interactive | nested) ;; *) exit 2 ;; esac

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/certs/add_cert.sh
source "$ROOT_DIR/lib/certs/add_cert.sh"
# shellcheck source=../lib/cli/command_visibility.sh
source "$ROOT_DIR/lib/cli/command_visibility.sh"
# shellcheck source=../lib/cli/run_command.sh
source "$ROOT_DIR/lib/cli/run_command.sh"

BASE_DIR="$(_realpath_portable "$2")"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
CERTS_DIR="$STATE_DIR/certs"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
BACKUP_DIR="$STATE_DIR/backups"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
NGINX_CONTAINER_NAME="certbot-pull-test-proxy"
CERTBOT_IMAGE="certbot/certbot:latest"
SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
VERBOSE=false
OUTPUT="$BASE_DIR/failure.log"
TRACE="$BASE_DIR/actions.log"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$TMP_DIR" "$ERROR_LOG_DIR" "$BACKUP_DIR"
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
printf 'before\n' >"$CONFIG_DIR/marker"
printf 'existing-certificate\n' >"$CERTS_DIR/marker.pem"
cp "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/settings.before"
: >"$TRACE"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function log_msg() { :; }
function audit_log() { :; }
function capture_docker_logs() { :; }
function check_certbot_installed() { :; }
function nginx_container_is_managed() { return 1; }
function nginx_container_conflict_exists() { return 1; }
function _certbot_docker_is_darwin_host() { return 1; }
function docker() { printf 'unexpected-docker\n' >>"$TRACE"; return 1; }
function update_nginx_config() { printf 'unexpected-render\n' >>"$TRACE"; return 1; }
function pull_image_if_autopull() {
  transaction_is_active || fail_test 'Pull failure did not occur inside a real transaction'
  [ -d "$(_transaction_lock_dir)" ] || fail_test 'Transaction did not hold its lock'
  [ -d "$CERTS_DIR/letsencrypt" ] || fail_test 'Certificate preparation did not run'
  [ -d "$ACME_WEBROOT_DIR" ] || fail_test 'ACME preparation did not run'
  # Model a failure after preparatory work, then prove the actual snapshot is
  # replayed instead of merely clearing the transaction bookkeeping.
  printf 'partial-preparation\n' >"$CONFIG_DIR/marker"
  printf 'partial-certificate\n' >"$CERTS_DIR/marker.pem"
  printf 'pull-failed\n' >>"$TRACE"
  return 1
}

case "$TEST_CASE" in
conditional)
  if add_cert example.com 443 letsencrypt >"$OUTPUT" 2>&1; then
    fail_test 'Conditional add_cert unexpectedly succeeded'
  fi
  ;;
interactive)
  INTERACTIVE=true
  # This is the same conditional dispatcher used by the interactive picker.
  if ! run_command add-cert example.com 443 letsencrypt >"$OUTPUT" 2>&1; then
    :
  else
    fail_test 'Interactive dispatch unexpectedly succeeded'
  fi
  ;;
nested)
  begin_transaction parent_operation "$CONFIG_DIR" "$CERTS_DIR" "$ACME_WEBROOT_DIR"
  printf 'parent-change\n' >"$CONFIG_DIR/marker"
  if ! add_cert example.com 443 letsencrypt >"$OUTPUT" 2>&1; then
    :
  else
    fail_test 'Nested add_cert unexpectedly succeeded'
  fi
  ;;
esac

if transaction_is_active; then fail_test 'Failed add_cert retained an active transaction'; fi
[ ! -e "$(_transaction_lock_dir)" ] || fail_test 'Failed add_cert retained its lock'
[ -z "${ROLLBACK_DESC:-}${PRE_CHANGE_BACKUP:-}${TRANSACTION_DEPTH:-}${TRANSACTION_OWNER_PID:-}${TRANSACTION_MODE:-}" ] ||
  fail_test 'Failed add_cert retained rollback metadata'
[ -z "$(trap -p ERR)" ] || fail_test 'Failed add_cert retained its ERR trap'
[ -z "$(trap -p EXIT)" ] || fail_test 'Failed add_cert retained its EXIT trap'
grep -qx before "$CONFIG_DIR/marker" || fail_test 'Failed add_cert did not restore config'
grep -qx existing-certificate "$CERTS_DIR/marker.pem" || fail_test 'Failed add_cert did not restore certificates'
cmp -s "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/settings.before" || fail_test 'Failed add_cert changed saved settings'
[ ! -e "$CERTS_DIR/letsencrypt" ] || fail_test 'Failed add_cert retained its new certificate directory'
[ ! -e "$ACME_WEBROOT_DIR" ] || fail_test 'Failed add_cert retained its new ACME directory'
grep -qx pull-failed "$TRACE" || fail_test 'Failure did not reach the pull boundary'
[ "$(wc -l <"$TRACE" | tr -d '[:space:]')" = 1 ] || fail_test 'Failed pull continued to Docker or rendering'
grep -Fq 'Rolled back.' "$OUTPUT" || fail_test 'Failed pull did not report rollback'

# A following successful operation must get its own transaction and survive
# both an unrelated later error and normal exit of the interactive shell.
begin_transaction later_operation "$CONFIG_DIR"
printf 'later-operation\n' >"$CONFIG_DIR/marker"
end_transaction_success
set +e
false
later_status=$?
set -e
[ "$later_status" -eq 1 ] || fail_test 'Unrelated failure status changed'
grep -qx later-operation "$CONFIG_DIR/marker" || fail_test 'Later operation was reverted'
[ -z "$(trap -p ERR)$(trap -p EXIT)" ] || fail_test 'Later operation retained transaction traps'
