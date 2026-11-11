#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_migration.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }; }
function state_fingerprint() {
  (cd "$TEST_WORK/state" && find config certs -type f -print | LC_ALL=C sort | while IFS= read -r file; do printf '%s\n' "$file"; cksum <"$file"; done)
}

# Model a 1.x installation whose backend image/lifecycle cannot be recovered
# without an operator-supplied details file. No Docker calls are available.
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; CERTS_DIR="$STATE_DIR/certs"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR/nginx_conf/conf.d" "$CERTS_DIR"
  config_reset_defaults
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  state_security_rules_use_schema 1
  state_csv_ensure_all_state_files
  printf '1\n' >"$CONFIG_DIR/state_schema_version"
  state_backend_ports_row_backend legacy.example.com 172.20.0.3:8080 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
  state_backend_ports_row_port legacy.example.com 18180 8080 http none no off '' >>"$BACKEND_PORTS_FILE"
  csv_join_row legacy.example.com response X-Migration 'Retain, "exactly"' >>"$BACKEND_HEADERS_FILE"
  printf '# Existing proxy configuration; migration must not reload or replace.\n' >"$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
)
cert_source="$TEST_WORK/state/certs/selfsigned/live/orphan.example.com_443"
mkdir -p "$cert_source"
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$cert_source/privkey.pem" -out "$cert_source/fullchain.pem" -subj /CN=orphan.example.com >/dev/null 2>&1
chmod 600 "$cert_source/privkey.pem"
state_fingerprint >"$TEST_WORK/before"

if "$BIN" migrate-state --dry-run >"$TEST_WORK/output" 2>&1; then fail_test 'migration guessed missing backend image'; fi
state_fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'failed preflight changed legacy state'
[ ! -d "$TEST_WORK/state/domains" ] || fail_test 'failed preflight created domain artifacts'

printf 'domain,image,state\nlegacy.example.com,nginx:alpine,stopped\n' >"$TEST_WORK/details.csv"
# Even a syntactically valid row must not disappear because its domain was
# absent from the primary backend inventory.
cp "$TEST_WORK/state/config/security_rules.csv" "$TEST_WORK/security-before"
(
  source "$TEST_WORK/lib/utils/csv.sh"
  fields=(1 ghost.example.com single 403 1 path - equals /blocked)
  while [ "${#fields[@]}" -lt 45 ]; do fields+=(""); done
  fields+=(- auto)
  csv_join_row "${fields[@]}" >>"$TEST_WORK/state/config/security_rules.csv"
)
state_fingerprint >"$TEST_WORK/orphan-before"
if "$BIN" migrate-state --dry-run --backend-details "$TEST_WORK/details.csv" >"$TEST_WORK/output" 2>&1; then fail_test 'migration silently discarded an orphan rule'; fi
state_fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/orphan-before" "$TEST_WORK/after" || fail_test 'orphan preflight changed legacy state'
cp "$TEST_WORK/security-before" "$TEST_WORK/state/config/security_rules.csv"
run_cli migrate-state --dry-run --backend-details "$TEST_WORK/details.csv"
state_fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'dry-run changed legacy state'
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 1 ] || fail_test 'dry-run updated schema marker'
[ ! -d "$TEST_WORK/state/domains" ] || fail_test 'dry-run created domain artifacts'

# Fail after the new sources and certificate material were placed. The existing
# transaction must remove those partial outputs and preserve the old schema.
cat >"$TEST_WORK/lib/domain_config/zz_migration_failure.sh" <<'EOF'
# shellcheck shell=bash
function _domain_config_publish_applied() { return 1; }
EOF
if "$BIN" migrate-state --backend-details "$TEST_WORK/details.csv" >"$TEST_WORK/output" 2>&1; then fail_test 'injected migration failure succeeded'; fi
rm "$TEST_WORK/lib/domain_config/zz_migration_failure.sh"
state_fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'failed migration changed legacy configuration or certificates'
[ ! -e "$TEST_WORK/state/domains/legacy.example.com/config" ] || fail_test 'failed migration left partial domain configuration'
[ ! -e "$TEST_WORK/state/domains/orphan.example.com/certs" ] || fail_test 'failed migration left partial certificate copies'

cp "$TEST_WORK/state/config/nginx_conf/conf.d/backends.conf" "$TEST_WORK/proxy-before"
cp "$TEST_WORK/state/config/backend_ports.csv" "$TEST_WORK/ports-before"
run_cli migrate-state --backend-details "$TEST_WORK/details.csv"
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 5 ] || fail_test 'migration did not publish schema marker'
domain="$TEST_WORK/state/domains/legacy.example.com"
[ "$(test_csv_field "$domain/config/backend.csv" image)" = 'nginx:alpine' ] || fail_test 'image was not imported'
[ "$(test_csv_field "$domain/runtime/applied/backend.csv" state)" = 'stopped' ] || fail_test 'stopped state was not imported'
grep -Fq 'X-Migration,"Retain, ""exactly"""' "$domain/config/headers.csv" || fail_test 'quoted header changed during migration'
cmp -s "$TEST_WORK/proxy-before" "$TEST_WORK/state/config/nginx_conf/conf.d/backends.conf" || fail_test 'migration changed live proxy configuration'
cmp -s "$TEST_WORK/ports-before" "$TEST_WORK/state/config/backend_ports.csv" || fail_test 'migration changed runtime upstream addresses'
orphan="$TEST_WORK/state/domains/orphan.example.com"
[ "$(test_csv_field "$orphan/config/domain.csv" role)" = 'certificate-only' ] || fail_test 'standalone certificate lost its owner'
cmp -s "$cert_source/fullchain.pem" "$orphan/certs/selfsigned-443/fullchain.pem" || fail_test 'standalone certificate was not copied intact'
cmp -s "$cert_source/privkey.pem" "$orphan/certs/selfsigned-443/privkey.pem" || fail_test 'standalone private key was not copied intact'
run_cli migrate-state
grep -Fq 'already uses schema 5' "$TEST_WORK/output" || fail_test 'migration was not idempotent'

# Operational commands publish diagnostic files even when no proxy render was
# requested. Those legacy-cache placeholders must not make first apply a no-op.
layout_marker="$TEST_WORK/state/config/nginx_conf/domain_layout_version"
[ ! -e "$layout_marker" ] || fail_test 'migration marked the legacy proxy layout as current'
run_cli set-backup-retention 1
[ -f "$domain/generated/nginx/http.conf" ] || fail_test 'operational command did not publish diagnostic placeholders'
[ ! -e "$layout_marker" ] || fail_test 'operational command marked unrendered placeholders as current'
run_cli apply-domain-config legacy.example.com
grep -Fq 'Applied domain configuration:' "$TEST_WORK/output" || fail_test 'first unchanged apply skipped migrated layout regeneration'
[ "$(cat "$layout_marker")" = 2 ] || fail_test 'first apply did not record the new renderer layout'
grep -Fq 'down;' "$TEST_WORK/state/config/nginx_conf/conf.d/backends.conf" || fail_test 'first regeneration lost stopped lifecycle state'
grep -Fq 'proxy_pass http://dockistrate_unavailable;' "$domain/generated/nginx/http.conf" || fail_test 'domain fragment routes to a stopped backend'
run_cli apply-domain-config legacy.example.com
grep -Fq 'Configuration and runtime are unchanged.' "$TEST_WORK/output" || fail_test 'matching rendered layout did not retain the no-op apply'
printf '[PASS] domain configuration migration\n'
