#!/usr/bin/env bash
# Fixture globals are consumed by production; expected Nginx variables are literal.
# shellcheck disable=SC2034,SC1091,SC2016
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
source "$ROOT_DIR/lib/utils.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-redirect-defaults.XXXXXXXX")"
TEST_COMPLETE=false
test_status=0
trap 'test_status=$?; rm -rf "$TEST_WORK"; if [ "$TEST_COMPLETE" != true ] && [ "$test_status" -eq 0 ]; then test_status=1; fi; exit "$test_status"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"
HOST="$TEST_WORK/state/domains/host.example.com"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function row_value() (
  local file="$1" identity="$2" field="$3" line="" index=0 column=-1 count=0 value=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  IFS= read -r line <"$file"
  csv_parse_line "$line" || return 1
  for ((index = 0; index < CSV_FIELD_COUNT; index++)); do
    [ "${CSV_FIELDS[index]}" != "$field" ] || column="$index"
  done
  [ "$column" -ge 0 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    csv_parse_line "$line" || return 1
    [ "${CSV_FIELDS[0]}" = "$identity" ] || continue
    count=$((count + 1)); value="${CSV_FIELDS[column]}"
  done <"$file"
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$value"
)
function assert_location() {
  local domain_dir="$1" port="$2" path="$3" expected="$4" body=""
  body="$(awk -v port="$port" -v path="$path" '
    $1 == "listen" && $2 == port ";" { server = 1 }
    server && $1 == "location" && $2 == path && $3 == "{" { location = 1; next }
    location && $1 == "}" { exit }
    location { sub(/^[ \t]+/, ""); print }
    $0 == "}" { server = 0 }
  ' "$domain_dir/generated/nginx/http.conf")"
  if [ "$expected" = proxy ]; then
    printf '%s\n' "$body" | grep -q '^proxy_pass http://' || fail_test "Expected proxy location $port$path for ${domain_dir##*/}"
    if printf '%s\n' "$body" | grep -q '^return '; then fail_test "Unexpected redirect in $port$path for ${domain_dir##*/}"; fi
  else
    printf '%s\n' "$body" | grep -Fxq "$expected" || fail_test "Wrong redirect in $port$path for ${domain_dir##*/}: $body"
  fi
}
function assert_path_policy() {
  local inherited="$1" domain_dir=""
  for domain_dir in "$DOMAIN" "$HOST"; do
    assert_location "$domain_dir" 38081 /auto "$inherited"
    assert_location "$domain_dir" 38081 /explicit 'return 301 https://$host:38444$request_uri;'
    assert_location "$domain_dir" 38081 /off proxy
  done
}
function assert_blanks_preserved() {
  local part="" line="" seen=0
  for part in config runtime/applied; do
    [ "$(row_value "$DOMAIN/$part/ports.csv" 38080 redirect_code)" = '' ] || fail_test 'Command export materialized the default listener code'
    [ "$(row_value "$DOMAIN/$part/path_options.csv" auto redirect_code)" = '' ] || fail_test 'Command export froze the inherited path code'
    [ "$(row_value "$HOST/$part/path_options.csv" own redirect_code)" = '' ] || fail_test 'Command export materialized the dedicated path code'
  done
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "$STATE_BACKEND_PORTS_HEADER" ] || continue
    state_backend_ports_parse_line "$line" || fail_test 'Invalid aggregate CSV'
    case "$STATE_BP_RECORD_TYPE:$STATE_BP_DOMAIN:$STATE_BP_LISTEN_PORT:$STATE_BP_PATH_PREFIX" in
    port:example.com:38080: | path:example.com:38081:/auto | path:host.example.com:38080:/own)
      [ "$STATE_BP_REDIRECT_CODE" = '' ] || fail_test 'Aggregate state froze a redirect default'
      seen=$((seen + 1))
      ;;
    esac
  done <"$TEST_WORK/state/config/backend_ports.csv"
  [ "$seen" -eq 3 ] || fail_test 'Missing default redirect rows in aggregate state'
}
function snapshot_serving() {
  mkdir -p "$TEST_WORK/before"
  cp -R "$DOMAIN/runtime/applied" "$TEST_WORK/before/applied"
  cp -R "$DOMAIN/generated" "$TEST_WORK/before/generated"
  cp -R "$HOST/generated" "$TEST_WORK/before/host-generated"
  cp -R "$TEST_WORK/state/config/nginx_conf" "$TEST_WORK/before/nginx_conf"
  cp "$TEST_WORK/state/config/backend_ports.csv" "$TEST_WORK/before/backend_ports.csv"
}
function assert_serving_unchanged() {
  diff -r "$TEST_WORK/before/applied" "$DOMAIN/runtime/applied" >/dev/null || fail_test 'Applied configuration changed without a successful apply'
  diff -r "$TEST_WORK/before/generated" "$DOMAIN/generated" >/dev/null || fail_test 'Generated backend configuration changed'
  diff -r "$TEST_WORK/before/host-generated" "$HOST/generated" >/dev/null || fail_test 'Generated dedicated-host configuration changed'
  diff -r "$TEST_WORK/before/nginx_conf" "$TEST_WORK/state/config/nginx_conf" >/dev/null || fail_test 'Shared generated configuration changed'
  cmp -s "$TEST_WORK/before/backend_ports.csv" "$TEST_WORK/state/config/backend_ports.csv" || fail_test 'Aggregate port state changed'
}

# A stopped backend avoids real Docker operations while the public commands
# still validate, compile, render, publish and export domain configuration.
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  mkdir -p "$CONFIG_DIR"
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
  domain_config_write_template example.com backend "$DOMAIN/config"
  _domain_csv_set "$DOMAIN/config/backend.csv" image nginx:alpine
  _domain_csv_set "$DOMAIN/config/backend.csv" state stopped
  csv_join_row 38080 8080 http '' '' no on '' off auto >>"$DOMAIN/config/ports.csv"
  csv_join_row 38081 8080 http '' '' no off '' off auto >>"$DOMAIN/config/ports.csv"
  for path in auto explicit off inherit; do
    csv_join_row "$path" 38081 "/$path" prefix 100 '' none '' >>"$DOMAIN/config/paths.csv"
  done
  {
    csv_join_row auto inherit on '' - auto
    csv_join_row explicit inherit on 301:38444 - auto
    csv_join_row off inherit off '' - auto
    csv_join_row inherit inherit inherit '' - auto
  } >>"$DOMAIN/config/path_options.csv"
  domain_config_write_template host.example.com dedicated "$HOST/config"
  _domain_csv_set "$HOST/config/domain.csv" target example.com
  csv_join_row own 38080 /own prefix 100 '' none '' >>"$HOST/config/paths.csv"
  csv_join_row own inherit on '' - auto >>"$HOST/config/path_options.csv"
)

run_cli validate-domain-config --all
run_cli apply-domain-config --all --dry-run
[ ! -e "$DOMAIN/runtime/applied" ] && [ ! -e "$HOST/runtime/applied" ] || fail_test 'Preview activated draft configuration'
run_cli apply-domain-config --all
assert_location "$DOMAIN" 38080 / 'return 301 https://$host$request_uri;'
assert_location "$HOST" 38080 /own 'return 301 https://$host$request_uri;'
assert_path_policy 'return 301 https://$host$request_uri;'
for domain_dir in "$DOMAIN" "$HOST"; do assert_location "$domain_dir" 38081 /inherit proxy; done
assert_blanks_preserved
run_cli list-path-options example.com 38081
for expected in '/auto ws=inherit redirect=on(inherit)' '/explicit ws=inherit redirect=on(301:38444)' '/off ws=inherit redirect=off' '/inherit ws=inherit redirect=inherit'; do
  grep -Fq "$expected" "$TEST_WORK/output" || fail_test "Incorrect redirect listing: $expected"
done
printf '[tests] Blank listener/path defaults validate, preview, apply and list correctly\n'

# Ordinary mutations must preserve blank declarations, so later listener
# changes remain effective for both owned and inherited dedicated-host paths.
run_cli set-port-redirect example.com 38081 on 302
assert_path_policy 'return 302 https://$host$request_uri;'
for domain_dir in "$DOMAIN" "$HOST"; do assert_location "$domain_dir" 38081 /inherit 'return 302 https://$host$request_uri;'; done
assert_blanks_preserved
run_cli set-port-redirect example.com 38081 on 308:39443
assert_path_policy 'return 308 https://$host:39443$request_uri;'
for domain_dir in "$DOMAIN" "$HOST"; do assert_location "$domain_dir" 38081 /inherit 'return 308 https://$host:39443$request_uri;'; done
assert_blanks_preserved
printf '[tests] Blank path codes follow listener status and target-port changes without freezing\n'

snapshot_serving
test_domain_csv_set "$DOMAIN/config/path_options.csv" auto redirect_code 302:49443
cp "$DOMAIN/config/path_options.csv" "$TEST_WORK/pending-paths.csv"
run_cli update-nginx-config
assert_serving_unchanged
cmp -s "$TEST_WORK/pending-paths.csv" "$DOMAIN/config/path_options.csv" || fail_test 'Rendering rewrote a pending redirect edit'

# Invalid nonblank input must not publish any of the pending draft changes.
test_domain_csv_set "$DOMAIN/config/path_options.csv" auto redirect_code '301; return 200'
cp "$DOMAIN/config/path_options.csv" "$TEST_WORK/invalid-paths.csv"
if "$BASH" "$BIN" apply-domain-config example.com >"$TEST_WORK/output" 2>&1; then fail_test 'Invalid redirect draft applied'; fi
assert_serving_unchanged
cmp -s "$TEST_WORK/invalid-paths.csv" "$DOMAIN/config/path_options.csv" || fail_test 'Rejected apply rewrote the invalid draft'
TEST_COMPLETE=true
printf '[PASS] redirect defaults preserve inheritance, explicit overrides and the draft/applied boundary\n'
