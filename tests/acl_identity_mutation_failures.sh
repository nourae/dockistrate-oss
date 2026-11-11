#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_acl_identity_failures.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }

# Each changed entrypoint must remain independently sourceable without relying
# on main-loader ordering or a preloaded security update helper.
for entrypoint in \
  global_settings/set_trusted_proxies global_settings/set_real_ip_recursive \
  headers/set_client_ip_header headers/set_backend_client_ip_header \
  headers/remove_backend_client_ip_header backends/set_dedicated_host_inherit; do
  "$BASH" -c 'unset BASE_DIR; source "$1"; declare -F _global_settings_update_nginx_config_for_security_change >/dev/null' \
    isolated-source "$ROOT_DIR/lib/$entrypoint.sh" || fail_test "Independent sourcing failed: $entrypoint"
done

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
eval "$(declare -f end_transaction_success | sed '1s/end_transaction_success/_test_end_transaction_success/')"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers/set_backend_client_ip_header.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers/remove_backend_client_ip_header.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends/set_dedicated_host_inherit.sh"

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
TRACE_FILE="$TMP_ROOT/trace"

function capture_docker_logs() { :; }
function log_msg() { :; }
function domain_exists() { [ "$1" = identity.test ]; }
function dedicated_host_exists() { [ "$1" = dedicated.identity.test ]; }
function docker() { fail_test 'This fixture must not call Docker'; }
function create_backup() {
  printf 'backup\n' >>"$TRACE_FILE"
  [ "$FAULT" != backup ]
}
function update_nginx_config() {
  printf 'update\n' >>"$TRACE_FILE"
  [ "${DOCKISTRATE_FORCE_NGINX_RECREATE:-}" = true ] || fail_test 'Identity update did not request proxy replacement'
  if [ "${SKIP_UPDATE_NGINX_CONFIG:-}" = true ]; then
    [ "${DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE:-}" = true ] || fail_test 'Deferred identity update lost replacement request'
    [ -z "${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-}" ] || fail_test 'Deferred identity update requested immediate readiness'
    return 0
  fi
  [ "${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-}" = true ] || fail_test 'Identity update did not request config readiness'
  printf 'attempted-policy\n' >"$CONFIG_DIR/generated-marker"
  [ "$FAULT" != update ]
}
# Inject failure at the setter's completion boundary. Real archive/restore
# implementations still run; the separate runtime-lifetime test covers a real
# post-change backup failure and the resulting proxy runtime restoration.
function end_transaction_success() {
  if [ "$FAULT" = finalize ]; then
    printf 'finalize\n' >>"$TRACE_FILE"
    return 1
  fi
  _test_end_transaction_success
}

function run_mutation() {
  case "$MUTATION" in
  set) set_backend_client_ip_header identity.test off ;;
  remove) remove_backend_client_ip_header identity.test ;;
  inheritance) set_dedicated_host_inherit dedicated.identity.test headers no ;;
  esac
}

function reset_case() {
  FAULT=none
  unset DOCKISTRATE_FORCE_NGINX_RECREATE DOCKISTRATE_SECURITY_NGINX_READY_CHECK
  unset DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE SKIP_UPDATE_NGINX_CONFIG
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR"
  config_reset_defaults
  save_config
  printf '%s\n' "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" 'identity.test,X-Client-IP' >"$BACKEND_CLIENT_IP_HEADER_FILE"
  printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 'dedicated.identity.test,yes,yes,yes,yes,yes' >"$CONFIG_DIR/dedicated_host_inheritance.csv"
  printf 'original-policy\n' >"$CONFIG_DIR/generated-marker"
  : >"$TRACE_FILE"
}

for MUTATION in set remove inheritance; do
  for fault_case in backup update finalize; do
    reset_case
    FAULT="$fault_case"
    before="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
    : >"$TRACE_FILE"
    status=0
    # Calling the mutation conditionally disables implicit errexit protection.
    # Exit-style entrypoints stay isolated, while explicit failure handling
    # must stop later stages and restore every prior config file.
    (if run_mutation; then exit 0; else exit 1; fi) >"$TMP_ROOT/failure-output" 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail_test "$MUTATION unexpectedly succeeded after $FAULT failed"
    after="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
    [ "$before" = "$after" ] || fail_test "$MUTATION/$FAULT did not restore saved and generated state"
    case "$FAULT" in
    backup) expected=backup ;;
    update) expected=$'backup\nupdate' ;;
    finalize) expected=$'backup\nupdate\nfinalize' ;;
    esac
    [ "$(cat "$TRACE_FILE")" = "$expected" ] || fail_test "$MUTATION/$FAULT continued past its failed stage"
    printf 'PASS: conditional %s failure at %s restores config and stops later stages\n' "$MUTATION" "$FAULT"
  done

  reset_case
  DOCKISTRATE_FORCE_NGINX_RECREATE=previous-force
  DOCKISTRATE_SECURITY_NGINX_READY_CHECK=previous-ready
  run_mutation >"$TMP_ROOT/success-output" 2>&1 || fail_test "$MUTATION success setup failed"
  [ "$DOCKISTRATE_FORCE_NGINX_RECREATE" = previous-force ] || fail_test "$MUTATION leaked replacement flag"
  [ "$DOCKISTRATE_SECURITY_NGINX_READY_CHECK" = previous-ready ] || fail_test "$MUTATION leaked readiness flag"
  [ "$(cat "$CONFIG_DIR/generated-marker")" = attempted-policy ] || fail_test "$MUTATION did not reach config update"

  reset_case
  SKIP_UPDATE_NGINX_CONFIG=true
  run_mutation >"$TMP_ROOT/deferred-output" 2>&1 || fail_test "$MUTATION deferred setup failed"
  [ "${DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE:-}" = true ] || fail_test "$MUTATION lost deferred replacement"
  [ -z "${DOCKISTRATE_FORCE_NGINX_RECREATE:-}${DOCKISTRATE_SECURITY_NGINX_READY_CHECK:-}" ] || fail_test "$MUTATION leaked flags after deferred update"
  [ "$(cat "$CONFIG_DIR/generated-marker")" = original-policy ] || fail_test "$MUTATION rendered a deferred update early"
  printf 'PASS: %s restores caller flags and preserves deferred replacement\n' "$MUTATION"
done

printf 'ACL identity mutation checks passed (9 failures, 6 success/deferred cases, 6 isolated sources).\n'
