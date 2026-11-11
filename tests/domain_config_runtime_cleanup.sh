#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_cleanup.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; CONFIG_DIR="$STATE_DIR/config"; TMP_DIR="$STATE_DIR/tmp"; CERTS_DIR="$STATE_DIR/certs"
DOMAINS_DIR="$STATE_DIR/domains"; BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
DOMAIN_CONFIG_ACTIVE=true; SKIP_DOCKER_CHECKS=false
mkdir -p "$CONFIG_DIR" "$TMP_DIR/.dockistrate_transaction.lock" "$DOMAINS_DIR/example.com/certs/used" \
  "$DOMAINS_DIR/example.com/certs/custom-8443" "$DOMAINS_DIR/example.com/mtls" "$STATE_DIR/shared/acme/live/example.com" \
  "$STATE_DIR/shared/certificate_receipts/example.com/custom-8443/fingerprint"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_port other.example.com 443 8080 https example.com/used no off '' >>"$BACKEND_PORTS_FILE"
_domain_cert_write_metadata "$DOMAINS_DIR/example.com/certs/used" letsencrypt 443
mkdir -p "$CERTS_DIR/custom/live/example.com_8443"
_domain_cert_write_metadata "$DOMAINS_DIR/example.com/certs/custom-8443" custom 8443 "$CERTS_DIR/custom/live/example.com_8443"
_domain_cert_write_metadata "$DOMAINS_DIR/example.com/certs/custom-8443" custom 8443
[ "$(_domain_runtime_get "$DOMAINS_DIR/example.com/certs/custom-8443/certificate.csv" source_ref)" = "$CERTS_DIR/custom/live/example.com_8443" ] || exit 1
printf 'fixture\n' >"$TMP_DIR/stale-file"
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function _backend_runtime_install_signal_traps() { :; }
function _backend_runtime_container_is_absent() { return 1; }
function _backend_runtime_is_full_container_id() { [ "${#1}" -eq 64 ]; }
function _backend_identity_inspect() { :; }
function nginx_container_is_managed() { return 0; }
function _nginx_prepare_runtime_rollback() {
  NGINX_RUNTIME_ROLLBACK_DEPTH=1
  NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED=true
  NGINX_RUNTIME_ROLLBACK_WAS_RUNNING=true
  NGINX_RUNTIME_ROLLBACK_IMAGE=nginx:alpine
  NGINX_RUNTIME_ROLLBACK_BINDINGS=80/tcp
  NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED=false
}
function docker() { [ "$1" = inspect ] || fail_test 'Runtime deletion occurred before commit'; printf '%s\n' "$PROXY_ID"; }
function remove_container_and_anonymous_volumes() { printf 'delete:%s\n' "$1" >>"$TEST_WORK/actions"; }
NGINX_CONTAINER_NAME=proxy; PROXY_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TRANSACTION_DEPTH=1 TRANSACTION_OWNER_PID="$$" TRANSACTION_LOCK_HELD=true ROLLBACK_DESC=cleanup
PRE_CHANGE_BACKUP="$STATE_DIR/before.tar.gz"; ROLLBACK_FILES=("$CONFIG_DIR"); ROLLBACK_NEW_FILES=()
domain_config_runtime_prepare
_domain_runtime_prepare_cleanup_proxy
[ "$(_domain_runtime_get "$DOMAIN_CONFIG_RUNTIME_JOURNAL/proxy.csv" NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED)" = true ] || fail_test 'Mounted-directory cleanup did not record proxy recreation before deletion'
domain_config_clean_owned_material example.com
[ -d "$DOMAINS_DIR/example.com/certs/used" ] || fail_test 'Shared certificate was deleted'
[ ! -d "$DOMAINS_DIR/example.com/certs/custom-8443" ] || fail_test 'Unreferenced certificate survived cleanup'
[ ! -d "$DOMAINS_DIR/example.com/mtls" ] || fail_test 'Owned authority survived cleanup'
[ -d "$STATE_DIR/shared/certificate_receipts/example.com/custom-8443" ] || fail_test 'Receipt deletion preceded commit'
[ -d "$CERTS_DIR/custom/live/example.com_8443" ] || fail_test 'Legacy copy deletion preceded commit'
# Explicit removal must still record the verified proxy when optional runtime
# validation is skipped, as in the broad CLI fixtures.
SKIP_DOCKER_CHECKS=true
_domain_runtime_stage_proxy_delete
SKIP_DOCKER_CHECKS=false
_domain_runtime_record remove backend.example.com old_id backend-id old_token backend-token
_domain_runtime_finish_operation
_domain_runtime_record shared_remove proxy.dockistrate.invalid scope all
_domain_runtime_finish_operation
[ ! -e "$TEST_WORK/actions" ] || fail_test 'Containers were destroyed before commit'
domain_config_runtime_commit
domain_config_runtime_cleanup
[ ! -d "$CERTS_DIR/custom/live/example.com_8443" ] || fail_test 'Explicit cleanup retained the legacy serving copy'
mkdir -p "$CERTS_DIR/custom/live/other.example.com_8443"
if _domain_cert_remove_legacy_material example.com custom-8443 "$CERTS_DIR/custom/live/other.example.com_8443" 2>/dev/null; then fail_test 'Legacy cleanup accepted another owner'; fi
[ -d "$CERTS_DIR/custom/live/other.example.com_8443" ] || fail_test 'Legacy cleanup removed another owner'
mkdir -p "$CERTS_DIR/selfsigned/live/example.com_443"
_domain_cert_remove_legacy_material example.com selfsigned-443 ''
[ ! -d "$CERTS_DIR/selfsigned/live/example.com_443" ] || fail_test 'Standard ID legacy fallback was not cleaned'
grep -q "^delete:$PROXY_ID$" "$TEST_WORK/actions" || fail_test 'Proxy deletion was not finalized by full ID'
grep -q '^delete:backend-id$' "$TEST_WORK/actions" || fail_test 'Backend deletion was not finalized'
[ ! -d "$STATE_DIR/shared/acme" ] && [ ! -d "$STATE_DIR/shared/certificate_receipts" ] || fail_test 'Issuer material survived uninstall commit'
[ -d "$TMP_DIR/.dockistrate_transaction.lock" ] || fail_test 'Committed cleanup deleted the held lock'
[ ! -e "$TMP_DIR/stale-file" ] || fail_test 'Uninstall retained temporary content'
rmdir "$TMP_DIR/.dockistrate_transaction.lock"
domain_config_runtime_post_release_cleanup
[ ! -e "$TMP_DIR" ] || fail_test 'Empty temporary root survived post-release cleanup'
printf '[PASS] domain deferred cleanup\n'
