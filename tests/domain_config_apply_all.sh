#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_apply_all.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }; }
function accepted_fingerprint() {
  (
    cd "$TEST_WORK/state"
    find config domains/a.example.com/runtime domains/a.example.com/generated \
      domains/b.example.com/runtime domains/b.example.com/generated -type f -print |
      LC_ALL=C sort | while IFS= read -r file; do printf '%s\n' "$file"; cksum <"$file"; done
  )
}
function draft_fingerprint() {
  (
    cd "$TEST_WORK/state"
    find domains/a.example.com/config domains/b.example.com/config -type f -print |
      LC_ALL=C sort | while IFS= read -r file; do printf '%s\n' "$file"; cksum <"$file"; done
  )
}

# Seed source templates directly, then exercise the real CLI for each apply.
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"
  for domain in a.example.com b.example.com; do
    destination="$DOMAINS_DIR/$domain/config"
    domain_config_write_template "$domain" backend "$destination"
    printf 'image,container_port,network,state\nnginx:alpine,8080,%s,stopped\n' "$DEFAULT_NETWORK" >"$destination/backend.csv"
    port=18180; [ "$domain" != b.example.com ] || port=18181
    printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n%s,8080,http,,,no,off,,off,auto\n' "$port" >"$destination/ports.csv"
  done
)
run_cli apply-domain-config --all
for domain in a.example.com b.example.com; do
  accepted="$TEST_WORK/state/domains/$domain/runtime/applied/backend.csv"
  [ "$(test_csv_field "$accepted" state)" = stopped ] || fail_test "$domain did not apply its stopped state"
  grep -Fq 'proxy_pass http://dockistrate_unavailable;' "$TEST_WORK/state/domains/$domain/generated/nginx/http.conf" || fail_test "$domain did not render its stopped route"
done
accepted_fingerprint >"$TEST_WORK/accepted-before"

for domain in a.example.com b.example.com; do
  config="$TEST_WORK/state/domains/$domain/config"
  test_domain_csv_set "$config/backend.csv" image httpd:alpine
  test_domain_csv_set "$config/backend.csv" container_port 9090
  port=18180; [ "$domain" != b.example.com ] || port=18181
  printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n%s,9090,http,,,no,off,,off,auto\n' "$port" >"$config/ports.csv"
done
draft_fingerprint >"$TEST_WORK/drafts-before"

# Mock-mode reconciliation writes metadata through this real helper instead of
# launching containers. Fail the second write only after both specs changed.
sed 's/^function domain_config_record_backend() {/function _test_apply_all_record_backend() {/' \
  "$TEST_WORK/lib/domain_config/runtime_backends.sh" >"$TEST_WORK/runtime_backends.sh"
mv "$TEST_WORK/runtime_backends.sh" "$TEST_WORK/lib/domain_config/runtime_backends.sh"
cat >"$TEST_WORK/lib/domain_config/zz_apply_all_failure.sh" <<'EOF'
# shellcheck shell=bash
function domain_config_record_backend() {
  _test_apply_all_record_backend "$@" || return 1
  if [ "$1" = b.example.com ] && [ -f "$BASE_DIR/fail-second-backend" ]; then
    [ "$(_domain_runtime_get "$STATE_DIR/domains/a.example.com/runtime/backend.csv" image)" = httpd:alpine ] || return 1
    [ "$(_domain_runtime_get "$STATE_DIR/domains/b.example.com/runtime/backend.csv" image)" = httpd:alpine ] || return 1
    printf 'both runtime specs changed\n' >"$BASE_DIR/failure-reached"
    printf '[Error] Injected failure after the second backend update.\n' >&2
    return 1
  fi
}
EOF
: >"$TEST_WORK/fail-second-backend"
if "$BIN" apply-domain-config --all >"$TEST_WORK/output" 2>&1; then fail_test 'Injected second-backend failure succeeded'; fi
[ -f "$TEST_WORK/failure-reached" ] || { cat "$TEST_WORK/output" >&2; fail_test 'Failure did not occur after both backend changes'; }
accepted_fingerprint >"$TEST_WORK/accepted-after"
cmp -s "$TEST_WORK/accepted-before" "$TEST_WORK/accepted-after" || fail_test 'Failed --all did not restore both runtime/applied/generated trees and aggregate files'
draft_fingerprint >"$TEST_WORK/drafts-after"
cmp -s "$TEST_WORK/drafts-before" "$TEST_WORK/drafts-after" || fail_test 'Failed --all discarded edited drafts'

rm "$TEST_WORK/fail-second-backend"
run_cli apply-domain-config --all
for domain in a.example.com b.example.com; do
  directory="$TEST_WORK/state/domains/$domain"
  for accepted in "$directory/runtime/backend.csv" "$directory/runtime/applied/backend.csv"; do
    [ "$(test_csv_field "$accepted" image)" = httpd:alpine ] || fail_test "$domain did not publish its new image"
    [ "$(test_csv_field "$accepted" container_port)" = 9090 ] || fail_test "$domain did not publish its new port"
    [ "$(test_csv_field "$accepted" state)" = stopped ] || fail_test "$domain lost its stopped state"
  done
done
grep -q 'a.example.com,.*9090' "$TEST_WORK/state/config/backend_ports.csv" || fail_test 'Successful --all omitted the first aggregate backend change'
grep -q 'b.example.com,.*9090' "$TEST_WORK/state/config/backend_ports.csv" || fail_test 'Successful --all omitted the second aggregate backend change'
draft_fingerprint >"$TEST_WORK/drafts-after"
cmp -s "$TEST_WORK/drafts-before" "$TEST_WORK/drafts-after" || fail_test 'Successful --all rewrote source drafts'
printf '[PASS] apply --all rollback and publication across two domains\n'
