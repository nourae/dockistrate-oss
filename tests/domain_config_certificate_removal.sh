#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_certificate_removal.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; CONFIG_DIR="$STATE_DIR/config"; CERTS_DIR="$STATE_DIR/certs"
DOMAINS_DIR="$STATE_DIR/domains"; BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
DOMAIN_CONFIG_ACTIVE=true; SKIP_DOCKER_CHECKS=true
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function _backend_runtime_install_signal_traps() { :; }
function update_nginx_config() { :; }
function create_backup() {
  [ -z "$1" ] && [ "$2" = "RemoveCert_${domain}_${port}" ] || fail_test 'Incorrect removal backup request'
  printf '%s\n' "$2" >>"$TEST_WORK/backup-requests"
}
function seed_certificate() {
  domain="$1"; certificate_id="$2"; port="$3"
  material="$DOMAINS_DIR/$domain/certs/$certificate_id"
  legacy="$CERTS_DIR/custom/live/${domain}_$port"
  mkdir -p "$material" "$legacy"
  printf 'legacy material\n' >"$legacy/marker"
  _domain_cert_write_metadata "$material" custom "$port" "$legacy"
  TRANSACTION_DEPTH=1 TRANSACTION_OWNER_PID="$$" TRANSACTION_LOCK_HELD=true
  ROLLBACK_DESC=certificate_removal PRE_CHANGE_BACKUP="$STATE_DIR/before.tar.gz"
  ROLLBACK_FILES=("$CONFIG_DIR"); ROLLBACK_NEW_FILES=()
  domain_config_runtime_prepare
}

seed_certificate remove.example.com public-tls 443
original_identity="$(_backup_directory_identity "$legacy")"
domain_config_remove_certificate "$domain" "$port"
[ "$(cat "$TEST_WORK/backup-requests")" = "RemoveCert_${domain}_${port}" ] || fail_test 'Removal omitted its backup request'
[ ! -e "$material" ] || fail_test 'Explicit removal retained the owned certificate metadata'
[ -d "$legacy" ] || fail_test 'Legacy material was deleted before commit'
record="$DOMAIN_CONFIG_RUNTIME_JOURNAL/operations/00000001.csv"
[ "$(_domain_runtime_get "$record" legacy_source_verified)" = yes ] || fail_test 'Removal did not verify the source reference before deleting metadata'
[ "$(_domain_runtime_get "$record" legacy_source_id)" = public-tls ] || fail_test 'Removal intent lost the descriptive certificate ID'
[ "$(_domain_runtime_get "$record" legacy_source_identity)" = "$original_identity" ] || fail_test 'Removal intent lost the legacy directory identity'
journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
domain_config_runtime_commit
domain_config_runtime_cleanup
[ ! -e "$legacy" ] || fail_test 'Explicit removal retained the descriptive certificate legacy copy'
[ ! -e "$journal" ] || fail_test 'Successful certificate cleanup retained its committed journal'

# Cleanup after restart has only its durable intent. A replaced path or symlink
# must survive; putting the verified directory back allows an idempotent retry.
seed_certificate retry.example.com descriptive-id 8443
_domain_cert_write_metadata "$material" custom "$port" "./certs/custom/./live/${domain}_$port/"
domain_config_clean_owned_material "$domain"
[ ! -e "$material" ] || fail_test 'Bulk removal retained the owned certificate metadata'
journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
domain_config_runtime_commit
mv "$legacy" "$legacy.saved"
mkdir -p "$TEST_WORK/outside"
printf 'unrelated material\n' >"$TEST_WORK/outside/marker"
ln -s "$TEST_WORK/outside" "$legacy"
if domain_config_runtime_cleanup >"$TEST_WORK/cleanup-error" 2>&1; then fail_test 'Deferred cleanup followed a replacement symlink'; fi
[ -L "$legacy" ] && [ -f "$TEST_WORK/outside/marker" ] || fail_test 'Symlink rejection removed unrelated material'
[ -d "$journal" ] || fail_test 'Incomplete deferred cleanup discarded its journal'
safe_rm_f "$legacy" "$CERTS_DIR/custom/live"
mkdir "$legacy"
printf 'replacement material\n' >"$legacy/marker"
if domain_config_runtime_recover >"$TEST_WORK/cleanup-error" 2>&1; then fail_test 'Deferred retry deleted a replacement directory'; fi
grep -qx 'replacement material' "$legacy/marker" || fail_test 'Directory identity mismatch lost replacement material'
safe_rm_rf "$legacy" "$CERTS_DIR/custom/live"
mv "$legacy.saved" "$legacy"
domain_config_runtime_recover
[ ! -e "$legacy" ] && [ ! -e "$journal" ] || fail_test 'Deferred retry could not complete without the original metadata'
domain_config_runtime_recover

for rejected in owner traversal; do
  seed_certificate "${rejected}.example.com" descriptive-id 9443
  if [ "$rejected" = owner ]; then
    unsafe_source="$CERTS_DIR/custom/live/other.example.com_9443"
    mkdir -p "$unsafe_source"
  else
    unsafe_source="$CERTS_DIR/custom/live/../outside"
  fi
  _domain_cert_write_metadata "$material" custom "$port" "$unsafe_source"
  if domain_config_remove_certificate "$domain" "$port" >"$TEST_WORK/cleanup-error" 2>&1; then fail_test "Removal accepted an unsafe $rejected reference"; fi
  [ -f "$material/certificate.csv" ] && [ -d "$legacy" ] || fail_test 'Rejected cleanup deleted material before establishing ownership'
  [ "$rejected" != owner ] || [ -d "$unsafe_source" ] || fail_test 'Rejected cleanup deleted another domain material'
  domain_config_runtime_rollback
done
printf '[PASS] descriptive certificate removal and deferred recovery\n'
