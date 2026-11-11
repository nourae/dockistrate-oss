#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_backup_restore.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }; }
function write_identity() {
  printf 'domain,container_id,ownership_token\nexample.com,%064d,%032d\n' "$1" "$1" >"$TEST_WORK/state/config/backend_identity.csv"
}

run_cli init-domain-config example.com
test_domain_csv_set "$DOMAIN/config/backend.csv" image nginx:alpine
test_domain_csv_set "$DOMAIN/config/backend.csv" state stopped
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,8080,http,,,no,off,,off,auto\n' >"$DOMAIN/config/ports.csv"
run_cli apply-domain-config example.com
run_cli init-domain-config unfinished.example.com
write_identity 1
mkdir -p "$DOMAIN/mtls"
printf '%s\n' private-test-material >"$DOMAIN/mtls/ca.key"
chmod 400 "$DOMAIN/mtls/ca.key"
printf '%s\n' 'unfinished,"draft' >"$DOMAIN/config/headers.csv"
run_cli create-backup domain-restore-test
backup="$(cat "$TEST_WORK/state/backups/last_full_backup.txt")"
[ -f "$backup" ] || [ -d "$backup" ] || fail_test 'Public backup path missing.'

# The current host identity must win over the archived one. Restoring the
# saved applied snapshot must also leave an unfinished source draft untouched.
write_identity 2
cp "$TEST_WORK/state/config/backend_identity.csv" "$TEST_WORK/current-identity"
cp "$DOMAIN/runtime/applied/headers.csv" "$DOMAIN/config/headers.csv"
# Model an intentional operator edit without relying on root bypassing mode
# 400. The archived copy retains its original restricted permissions.
chmod u+w "$DOMAIN/mtls/ca.key"
printf '%s\n' changed-material >"$DOMAIN/mtls/ca.key"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$DOMAIN/config/settings.csv"
cp "$DOMAIN/config/settings.csv" "$DOMAIN/runtime/applied/settings.csv"
run_cli restore-backup "$backup"
cmp -s "$TEST_WORK/current-identity" "$TEST_WORK/state/config/backend_identity.csv" || fail_test 'Restore imported a stale archived container identity.'
grep -q '^unfinished,"draft$' "$DOMAIN/config/headers.csv" || fail_test 'Restore lost the pending draft.'
[ "$(test_csv_field "$DOMAIN/runtime/applied/backend.csv" state)" = 'stopped' ] || fail_test 'Restore did not honor stopped backend state.'
grep -q '^private-test-material$' "$DOMAIN/mtls/ca.key" || fail_test 'Restore lost private material.'
[ "$(stat -c '%a' "$DOMAIN/mtls/ca.key" 2>/dev/null || stat -f '%Lp' "$DOMAIN/mtls/ca.key")" = 400 ] || fail_test 'Restore widened the archived private-key mode.'
[ ! -e "$TEST_WORK/state/domains/unfinished.example.com/runtime/applied" ] || fail_test 'Restore applied a draft-only domain.'
grep -q 'down;' "$TEST_WORK/state/config/nginx_conf/conf.d/backends.conf" || fail_test 'Restored stopped backend has a live upstream.'
grep -q 'proxy_pass http://dockistrate_unavailable;' "$DOMAIN/generated/nginx/http.conf" || fail_test 'Stopped domain fragment does not use its unavailable upstream.'
if [ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http1.0' ]; then fail_test 'Restore retained newer applied settings.'; fi
run_cli status
grep -q 'invalid draft' "$TEST_WORK/output" || fail_test 'Restored draft must remain visible as invalid and pending.'

# Restoring an older snapshot must not silently orphan a newer managed backend.
extra="$TEST_WORK/state/domains/extra.example.com"
mkdir -p "$extra/runtime"
cp -R "$DOMAIN/runtime/applied" "$extra/config"
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n' >"$extra/config/ports.csv"
cp -R "$extra/config" "$extra/runtime/applied"
printf 'extra.example.com\n' >>"$TEST_WORK/state/config/domain_inventory.csv"
(
  source "$TEST_WORK/lib/utils/csv.sh"
  source "$TEST_WORK/lib/utils/state_csv.sh"
  state_backend_ports_row_backend extra.example.com 127.0.0.1:8080 dockistrate-net >>"$TEST_WORK/state/config/backend_ports.csv"
)
printf 'extra.example.com,%064d,%032d\n' 3 3 >>"$TEST_WORK/state/config/backend_identity.csv"
cp "$TEST_WORK/state/config/backend_identity.csv" "$TEST_WORK/with-extra-identity"
if "$BIN" restore-backup "$backup" >"$TEST_WORK/output" 2>&1; then fail_test 'Restore silently orphaned a backend omitted from the backup.'; fi
grep -q 'Remove each backend explicitly' "$TEST_WORK/output" || fail_test 'Omitted backend refusal did not explain the required cleanup.'
cmp -s "$TEST_WORK/with-extra-identity" "$TEST_WORK/state/config/backend_identity.csv" || fail_test 'Refused restore changed backend identities.'
[ -f "$extra/runtime/applied/backend.csv" ] || fail_test 'Refused restore removed the omitted backend state.'
run_cli remove-backend extra.example.com

# A failure after domain publication restores the complete pre-restore state.
chmod u+w "$DOMAIN/mtls/ca.key"
printf '%s\n' newer-private-material >"$DOMAIN/mtls/ca.key"
cp "$DOMAIN/runtime/applied/headers.csv" "$DOMAIN/config/headers.csv"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$DOMAIN/config/settings.csv"
cp "$DOMAIN/config/settings.csv" "$DOMAIN/runtime/applied/settings.csv"
cp "$DOMAIN/runtime/applied/settings.csv" "$TEST_WORK/before-settings"
cp "$DOMAIN/generated/nginx/http.conf" "$TEST_WORK/before-generated"
cat >"$TEST_WORK/lib/nginx/zz_restore_failure.sh" <<'EOF'
# shellcheck shell=bash
function update_nginx_config() {
  printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp2,,,,,\n' >"$STATE_DIR/domains/example.com/config/settings.csv"
  return "${RESTORE_TEST_RENDER_STATUS:-1}"
}
EOF
for render_status in 1 0; do
  if RESTORE_TEST_RENDER_STATUS="$render_status" "$BIN" restore-backup "$backup" >"$TEST_WORK/output" 2>&1; then
    fail_test 'Restore committed across a concurrent source edit.'
  fi
  [ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http2' ] || fail_test 'Restore rollback overwrote concurrent source edits.'
  cmp -s "$TEST_WORK/before-settings" "$DOMAIN/runtime/applied/settings.csv" || fail_test 'Failed restore changed applied configuration.'
  cmp -s "$TEST_WORK/before-generated" "$DOMAIN/generated/nginx/http.conf" || fail_test 'Failed restore changed generated configuration.'
  cmp -s "$TEST_WORK/current-identity" "$TEST_WORK/state/config/backend_identity.csv" || fail_test 'Failed restore changed current identity.'
  grep -q '^newer-private-material$' "$DOMAIN/mtls/ca.key" || fail_test 'Failed restore changed private material.'
  if [ "$render_status" -eq 0 ]; then
    grep -q 'Files changed before commit' "$TEST_WORK/output" || fail_test 'Successful rendering bypassed the final source conflict check.'
  fi
done
rm "$TEST_WORK/lib/nginx/zz_restore_failure.sh"

# Legacy config-only archives cannot include private material that they never
# backed up. Conversion recovers still-local certificates without moving their
# originals and prefers this host's current shared renewal state.
legacy="$TEST_WORK/legacy-backup"
mkdir -p "$legacy/config" "$TEST_WORK/state/shared/acme/renewal" "$TEST_WORK/state/certs/letsencrypt/renewal"
cp "$TEST_WORK/state/config/"*.csv "$legacy/config/"
printf '1\n' >"$legacy/config/state_schema_version"
rm -f "$legacy/config/domain_inventory.csv"
printf 'current issuer settings\n' >"$TEST_WORK/state/shared/acme/renewal/current.conf"
printf 'retained issuer settings\n' >"$TEST_WORK/state/certs/letsencrypt/renewal/legacy.conf"
legacy_cert="$TEST_WORK/state/certs/selfsigned/live/orphan.example.com_443"
mkdir -p "$legacy_cert"
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$legacy_cert/privkey.pem" -out "$legacy_cert/fullchain.pem" -subj /CN=orphan.example.com >/dev/null 2>&1
chmod 400 "$legacy_cert/privkey.pem"
cp "$legacy_cert/privkey.pem" "$TEST_WORK/original-key"
(
  source "$TEST_WORK/lib/utils/csv.sh"
  source "$TEST_WORK/lib/utils/state_csv.sh"
  # Genuine config-only backups predate the action column.
  printf '%s\n' "$STATE_SECURITY_RULES_LEGACY_HEADER" >"$legacy/config/security_rules.csv"
  state_backend_ports_row_backend legacy.example.com 172.20.0.4:8080 dockistrate-net >>"$legacy/config/backend_ports.csv"
  state_backend_ports_row_port legacy.example.com 18181 8080 http none no off '' >>"$legacy/config/backend_ports.csv"
)
printf 'domain,container_id,ownership_token\nexample.com,%064d,%032d\nlegacy.example.com,%064d,%032d\n' 9 9 8 8 >"$legacy/config/backend_identity.csv"
if "$BIN" restore-backup "$legacy" >"$TEST_WORK/output" 2>&1; then fail_test 'Legacy restore guessed a missing backend image.'; fi
cmp -s "$TEST_WORK/current-identity" "$TEST_WORK/state/config/backend_identity.csv" || fail_test 'Failed legacy conversion imported archived identities.'
printf 'domain,image,state\nlegacy.example.com,nginx:alpine,stopped\n' >"$TEST_WORK/backend-details.csv"
run_cli restore-backup "$legacy" --backend-details "$TEST_WORK/backend-details.csv"
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 5 ] || fail_test 'Legacy restore did not convert the schema.'
[ "$(test_csv_field "$TEST_WORK/state/domains/legacy.example.com/config/backend.csv" image)" = 'nginx:alpine' ] || fail_test 'Legacy restore lost supplied backend details.'
[ "$(test_csv_field "$TEST_WORK/state/domains/legacy.example.com/runtime/applied/backend.csv" state)" = 'stopped' ] || fail_test 'Legacy restore lost supplied stopped state.'
cmp -s "$TEST_WORK/current-identity" "$TEST_WORK/state/config/backend_identity.csv" || fail_test 'Legacy restore replaced current identities with archived IDs.'
cmp -s "$TEST_WORK/original-key" "$legacy_cert/privkey.pem" || fail_test 'Legacy restore changed original certificate material.'
cmp -s "$TEST_WORK/original-key" "$TEST_WORK/state/domains/orphan.example.com/certs/selfsigned-443/privkey.pem" || fail_test 'Legacy restore omitted retained certificate material.'
grep -q '^current issuer settings$' "$TEST_WORK/state/shared/acme/renewal/current.conf" || fail_test 'Legacy restore replaced current shared renewal state.'
grep -q '^retained issuer settings$' "$TEST_WORK/state/certs/letsencrypt/renewal/legacy.conf" || fail_test 'Legacy restore changed original issuer state.'
printf '%s\n' '[tests] domain_config_backup_restore.sh: PASS'
