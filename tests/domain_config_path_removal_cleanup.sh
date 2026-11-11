#!/usr/bin/env bash
# Fixture globals are consumed by production configuration and prompt helpers.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -eq 0 ]; then
  for test_case in single bulk; do
    "$BASH" "${BASH_SOURCE[0]}" "$test_case"
  done
  exit 0
fi
TEST_CASE="$1"
case "$TEST_CASE" in single | bulk) ;; *) exit 2 ;; esac
source "$ROOT_DIR/tests/helpers/path_choice_prompts.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-path-removal.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1 LC_ALL=C
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"
BACKEND_PORTS_FILE="$TEST_WORK/state/config/backend_ports.csv"
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }

function snapshot_state() {
  python3 - "$TEST_WORK" "$1" <<'PY'
import hashlib, json, pathlib, sys
root, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
state = root / 'state'
files = list((state / 'config').glob('*.csv'))
files += list((state / 'config/nginx_conf').rglob('*'))
for domain in (state / 'domains').iterdir():
    for part in ['config', 'runtime/applied', 'generated']:
        files += list((domain / part).rglob('*'))
result = {str(f.relative_to(state)): hashlib.sha256(f.read_bytes()).hexdigest()
          for f in files if f.is_file()}
output.write_text(json.dumps(result, sort_keys=True))
PY
}

function assert_unchanged() {
  snapshot_state "$TEST_WORK/after.json"
  cmp -s "$TEST_WORK/before.json" "$TEST_WORK/after.json" || fail_test 'Rejected removal changed source, applied, aggregate or generated state'
}

function assert_removed() {
  python3 - "$TEST_WORK" "$1" <<'PY'
import csv, json, pathlib, re, sys
root, phase = pathlib.Path(sys.argv[1]), sys.argv[2]
state = root / 'state'
initial = json.loads((root / 'initial.json').read_text())
dependents = {'inherited.example.com': 'example.com', 'independent.example.com': 'example.com'}
def removed(domain, port, path):
    if phase == 'global': return True
    if domain != 'example.com': return False
    if phase == 'domain': return True
    return port == '38080' and (path == '/api|assets' or
                              (phase == 'literal-and-regex' and path == '/(api|assets)'))
def rows(path):
    with path.open(newline='') as stream: return list(csv.DictReader(stream))
def expected_rows(key, original):
    domain = key.split('/')[1] if key.startswith('domains/') else ''
    if key.endswith('/paths.csv'):
        return [r for r in original if not removed(domain, r['listen_port'], r['path_prefix'])]
    if key.endswith('/nginx_directives.csv'):
        return [r for r in original if not (r['scope'] == 'path' and
                removed(dependents.get(r.get('domain', domain), r.get('domain', domain)),
                        r['listen_port'], r['path_prefix']))]
    if key == 'config/backend_ports.csv':
        return [r for r in original if not (r['record_type'] == 'path' and
                removed(r['domain'], r['listen_port'], r['path_prefix']))]
    return original
for key, original in initial['csv'].items():
    actual, expected = rows(state / key), expected_rows(key, original)
    if actual != expected:
        raise SystemExit('[FAIL] Wrong cleanup in %s: expected %s rows, got %s; row values differ' % (key, len(expected), len(actual)))
# Check emitted locations and both managed/raw values, not only CSV deletion.
for domain in ['example.com', 'inherited.example.com', 'independent.example.com', 'other.example.com']:
    text = (state / 'domains' / domain / 'generated/nginx/http.conf').read_text()
    owner = dependents.get(domain, domain)
    paths = initial['csv']['domains/%s/runtime/applied/paths.csv' % owner]
    expected_count = sum(not removed(owner, r['listen_port'], r['path_prefix'])
                         for r in paths if r['path_prefix'] == '/api|assets')
    if domain == 'independent.example.com': expected_count = 0
    actual_count = len(re.findall(r'location\s+(?:\^~\s+)?/api\|assets\s*\{', text))
    if actual_count != expected_count:
        raise SystemExit('[FAIL] Wrong generated literal-path count for %s: %s != %s' % (domain, actual_count, expected_count))
    if removed('example.com', '38080', '/api|assets') and domain in ['example.com', 'inherited.example.com']:
        for value in ['11s', '12s', '51s', '52s']:
            assert not re.search(r'proxy_(?:read|send)_timeout\s+' + value + ';', text), (domain, value)
if phase != 'global':
    other = (state / 'domains/other.example.com/generated/nginx/http.conf').read_text()
    assert other == initial['other_generated'], 'Unrelated domain generated configuration changed'
PY
}

# Stopped backends avoid Docker while every mutation still goes through the
# public dispatcher, domain export, validation, real rendering and publication.
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  mkdir -p "$CONFIG_DIR"
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
  for name in example.com other.example.com; do
    config="$TEST_WORK/state/domains/$name/config"
    domain_config_write_template "$name" backend "$config"
    _domain_csv_set "$config/backend.csv" image nginx:alpine
    _domain_csv_set "$config/backend.csv" state stopped
    csv_join_row 38080 8080 http '' '' no off '' off auto >>"$config/ports.csv"
    csv_join_row pipe 38080 '/api|assets' prefix 20 '' none '' >>"$config/paths.csv"
    csv_join_row path 38080 '/api|assets' managed proxy_read_timeout 41s >>"$config/nginx_directives.csv"
  done
  config="$DOMAIN/config"
  # The /api sentinel and same literal path on another listener must survive.
  _domain_csv_write_header "$config/paths.csv"
  {
    csv_join_row sentinel 38080 /api prefix 10 '' none ''
    csv_join_row pipe 38080 '/api|assets' prefix 20 '' none ''
    csv_join_row regex 38080 '/(api|assets)' regex 30 '' none ''
    csv_join_row other-port 38081 '/api|assets' prefix 40 '' none ''
  } >>"$config/paths.csv"
  csv_join_row 38081 8080 http '' '' no off '' off auto >>"$config/ports.csv"
  _domain_csv_write_header "$config/nginx_directives.csv"
  {
    csv_join_row path 38080 '/api|assets' managed proxy_read_timeout 11s
    csv_join_row path 38080 '/api|assets' raw proxy_send_timeout 12s
    csv_join_row path 38080 /api managed proxy_read_timeout 21s
    csv_join_row path 38081 '/api|assets' managed proxy_read_timeout 31s
    csv_join_row path 38080 '/(api|assets)' raw proxy_send_timeout 32s
    csv_join_row backend '' '' managed send_timeout 70s
    csv_join_row port 38080 '' managed proxy_read_timeout 71s
  } >>"$config/nginx_directives.csv"
  for name in inherited.example.com independent.example.com; do
    config="$TEST_WORK/state/domains/$name/config"
    domain_config_write_template "$name" dedicated "$config"
    _domain_csv_set "$config/domain.csv" target example.com
    if [ "$name" = independent.example.com ]; then
      _domain_csv_set "$config/inheritance.csv" paths no
    fi
    {
      csv_join_row path 38080 '/api|assets' managed proxy_read_timeout 51s
      csv_join_row path 38080 '/api|assets' raw proxy_send_timeout 52s
      csv_join_row path 38081 '/api|assets' managed proxy_read_timeout 61s
      csv_join_row backend '' '' managed send_timeout 72s
    } >>"$config/nginx_directives.csv"
  done
  csv_join_row global '' '' '' managed send_timeout 73s >>"$NGINX_DIRECTIVES_FILE"
  csv_join_row stream-global '' '' '' managed proxy_timeout 74s >>"$NGINX_DIRECTIVES_FILE"
)
run_cli apply-domain-config --all
python3 - "$TEST_WORK" <<'PY'
import csv, json, pathlib, sys
root = pathlib.Path(sys.argv[1]); state = root / 'state'
files = [state / 'config/backend_ports.csv', state / 'config/nginx_directives.csv']
for domain in (state / 'domains').iterdir():
    for part in ['config', 'runtime/applied']:
        files += [domain / part / name for name in ['paths.csv', 'nginx_directives.csv']]
result = {}
for path in files:
    with path.open(newline='') as stream: result[str(path.relative_to(state))] = list(csv.DictReader(stream))
assert all(not r['header_set'] for r in result['config/backend_ports.csv'] if r['record_type'] == 'path'), 'Fixture must exercise paths without header sets'
(root / 'initial.json').write_text(json.dumps({'csv': result,
    'other_generated': (state / 'domains/other.example.com/generated/nginx/http.conf').read_text()}))
PY
printf '[tests] %s fixture applied with headerless paths and managed/raw directives\n' "$TEST_CASE"

if [ "$TEST_CASE" = bulk ]; then
  run_cli remove-all-path-options example.com
  assert_removed domain
  printf '[tests] Domain bulk cleanup preserves other domains and non-path scopes\n'
  run_cli remove-all-path-options
  assert_removed global
  printf '[PASS] Public domain and global bulk removal clean headerless paths and dependent directives\n'
  exit 0
fi

# The actual picker must deliver the complete literal path to the public CLI.
collect_path_choice remove-path-option 2 >"$TEST_WORK/prompt-output" || fail_test 'Remove picker failed'
[ "${SELECTED_ARGS[2]}" = '/api|assets' ] || fail_test 'Picker selected the wrong literal path'
run_cli "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
assert_removed literal
printf '[tests] Picker removal publishes exact path and dependent directive cleanup\n'

# Pending source edits remain protected before mutation begins.
cp "$DOMAIN/config/settings.csv" "$TEST_WORK/clean-settings"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$DOMAIN/config/settings.csv"
snapshot_state "$TEST_WORK/before.json"
if "$BASH" "$BIN" remove-path-option example.com 38080 '/(api|assets)' >"$TEST_WORK/output" 2>&1; then
  fail_test 'Removal ignored pending draft edits'
fi
grep -q 'Unapplied or invalid edits' "$TEST_WORK/output" || fail_test 'Pending draft refusal was not reported'
assert_unchanged
cp "$TEST_WORK/clean-settings" "$DOMAIN/config/settings.csv"

# Removing a backend path also changes stored dedicated-host overrides. A
# pending edit in that dependent owner must not be silently overwritten.
dependent="$TEST_WORK/state/domains/independent.example.com/config"
cp "$dependent/settings.csv" "$TEST_WORK/clean-dependent-settings"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$dependent/settings.csv"
snapshot_state "$TEST_WORK/before.json"
if "$BASH" "$BIN" remove-path-option example.com 38081 '/api|assets' >"$TEST_WORK/output" 2>&1; then
  fail_test 'Removal overwrote a pending dedicated-host draft'
fi
grep -qi 'unapplied\|pending\|source.*changed' "$TEST_WORK/output" || fail_test 'Dependent draft refusal was not reported'
assert_unchanged
cp "$TEST_WORK/clean-dependent-settings" "$dependent/settings.csv"
printf '[tests] Primary and affected dedicated-host drafts survive rejected removals\n'

# Exercise a cleanup error after the helper has actually removed directives.
# The command must fail and roll back instead of committing a partial cleanup.
cat >"$TEST_WORK/lib/nginx_directives/zz_path_cleanup_failure.sh" <<'HOOK'
# shellcheck shell=bash
eval "$(declare -f nginx_directives_state_remove_for_paths | sed '1s/nginx_directives_state_remove_for_paths/_test_path_cleanup_helper/')"
function nginx_directives_state_remove_for_paths() {
  _test_path_cleanup_helper "$@" || return 1
  cp "$NGINX_DIRECTIVES_FILE" "$BASE_DIR/helper-failed-directives"
  printf '[Error] Injected path directive cleanup failure.\n' >&2
  return 1
}
HOOK
snapshot_state "$TEST_WORK/before.json"
if "$BASH" "$BIN" remove-path-option example.com 38080 '/(api|assets)' >"$TEST_WORK/output" 2>&1; then
  fail_test 'Removal ignored a directive cleanup failure'
fi
grep -q 'Injected path directive cleanup failure' "$TEST_WORK/output" || fail_test 'Cleanup failure hook was not reached'
python3 - "$TEST_WORK/helper-failed-directives" <<'PY'
import csv, pathlib, sys
with pathlib.Path(sys.argv[1]).open(newline='') as stream:
    assert not any(r['path_prefix'] == '/(api|assets)' for r in csv.DictReader(stream)), 'Helper failed before its mutation'
PY
assert_unchanged
rm "$TEST_WORK/lib/nginx_directives/zz_path_cleanup_failure.sh"
printf '[tests] Directive helper failure rolls back its completed mutation\n'

# Fail after real rendering has seen both removals; rollback must restore all
# aggregate, editable, applied and generated files as one operation.
cat >"$TEST_WORK/lib/nginx/zz_path_removal_failure.sh" <<'HOOK'
# shellcheck shell=bash
eval "$(declare -f _update_nginx_config_from_validated_settings | sed '1s/_update_nginx_config_from_validated_settings/_test_path_cleanup_render/')"
function _update_nginx_config_from_validated_settings() {
  _test_path_cleanup_render || return 1
  cp "$BACKEND_PORTS_FILE" "$BASE_DIR/failed-ports"
  cp "$NGINX_DIRECTIVES_FILE" "$BASE_DIR/failed-directives"
  printf '[Error] Injected failure after path cleanup rendering.\n' >&2
  return 1
}
HOOK
snapshot_state "$TEST_WORK/before.json"
if "$BASH" "$BIN" remove-path-option example.com 38080 '/(api|assets)' >"$TEST_WORK/output" 2>&1; then
  fail_test 'Removal ignored a rendering failure'
fi
grep -q 'Injected failure after path cleanup rendering' "$TEST_WORK/output" || fail_test 'Rollback did not reach the intended failure point'
python3 - "$TEST_WORK" <<'PY'
import csv, pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ['failed-ports', 'failed-directives']:
    with (root / name).open(newline='') as stream:
        assert not any(r.get('path_prefix') == '/(api|assets)' for r in csv.DictReader(stream)), name
PY
assert_unchanged
rm "$TEST_WORK/lib/nginx/zz_path_removal_failure.sh"
run_cli remove-path-option example.com 38080 '/(api|assets)'
assert_removed literal-and-regex
printf '[PASS] CLI and picker path removal clean exact dependencies, preserve unrelated rows and roll back failures\n'
