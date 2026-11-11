#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-certificate-backup.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"
BACKUPS="$TEST_WORK/state/backups"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256; }

# Exercise real CLI publication, material recovery and automatic snapshots.
# Fail only the final full backup, after removal and source publication.
cat >"$TEST_WORK/lib/domain_config/zz_certificate_backup_test.sh" <<'HOOK'
# shellcheck shell=bash
eval "$(declare -f domain_config_backup_write | sed '1s/domain_config_backup_write/_test_certificate_backup_write/')"
function domain_config_backup_write() {
  case "$1" in
  "$BACKUP_DIR"/*) [ "${FAIL_CERTIFICATE_BACKUP:-false}" != true ] || return 1 ;;
  esac
  _test_certificate_backup_write "$@"
}
HOOK

run_cli init-domain-config example.com --kind certificate-only
run_cli set-backup-compression false
run_cli apply-domain-config example.com
run_cli add-cert example.com 38443 selfsigned
material="$DOMAIN/certs/selfsigned-38443/fullchain.pem"
before="$(fingerprint "$material")"
backup="$(cat "$BACKUPS/last_full_backup.txt")"
checksum="$(cat "$BACKUPS/last_full_backup.sha256")"
[ -f "$backup/domains/example.com/certs/selfsigned-38443/fullchain.pem" ] || fail_test 'Initial backup omitted the certificate'
cp "$DOMAIN/config/certificates.csv" "$TEST_WORK/before.csv"

if FAIL_CERTIFICATE_BACKUP=true "$BASH" "$BIN" remove-cert example.com 38443 >"$TEST_WORK/output" 2>&1; then
  fail_test 'Removal committed despite a failed automatic snapshot'
fi
grep -q 'Rolled back\.' "$TEST_WORK/output" || fail_test 'Snapshot failure did not finish recovery'
[ "$(fingerprint "$material")" = "$before" ] || fail_test 'Failed removal lost certificate material'
cmp -s "$TEST_WORK/before.csv" "$DOMAIN/config/certificates.csv" || fail_test 'Failed removal changed editable declarations'
cmp -s "$TEST_WORK/before.csv" "$DOMAIN/runtime/applied/certificates.csv" || fail_test 'Failed removal changed applied declarations'
[ "$(cat "$BACKUPS/last_full_backup.txt")" = "$backup" ] || fail_test 'Failed removal replaced the backup pointer'
[ "$(cat "$BACKUPS/last_full_backup.sha256")" = "$checksum" ] || fail_test 'Failed removal replaced the backup checksum'

run_cli remove-cert example.com 38443
removed_backup="$(cat "$BACKUPS/last_full_backup.txt")"
[ "$removed_backup" != "$backup" ] || fail_test 'Successful removal left a stale automatic backup'
[ ! -e "$material" ] || fail_test 'Successful removal retained certificate material'
[ ! -e "$removed_backup/domains/example.com/certs/selfsigned-38443" ] || fail_test 'Latest backup would resurrect removed certificate material'
for declarations in "$DOMAIN/config/certificates.csv" "$DOMAIN/runtime/applied/certificates.csv" \
  "$removed_backup/domains/example.com/config/certificates.csv" "$removed_backup/domains/example.com/runtime/applied/certificates.csv"; do
  # Explicitly removing its last certificate can remove a certificate-only
  # owner too. Neither an absent table nor a header-only table retains a claim.
  [ -e "$declarations" ] || continue
  [ "$(wc -l <"$declarations" | tr -d '[:space:]')" = 1 ] || fail_test "Removed certificate declaration remains in $declarations"
done
printf '[PASS] certificate removal backs up final declarations and recovers material on snapshot failure\n'
