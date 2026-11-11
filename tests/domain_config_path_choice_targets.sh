#!/usr/bin/env bash
# Fixture globals are consumed by production configuration and prompt helpers.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/path_choice_prompts.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-path-choice-targets.XXXXXXXX")"
TEST_COMPLETE=false
test_status=0
trap 'test_status=$?; rm -rf "$TEST_WORK"; if [ "$TEST_COMPLETE" != true ] && [ "$test_status" -eq 0 ]; then test_status=1; fi; exit "$test_status"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1 LC_ALL=C
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"
BACKEND_PORTS_FILE="$TEST_WORK/state/config/backend_ports.csv"
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function assert_paths() {
  python3 - "$DOMAIN" "$1" "$2" <<'PY'
import csv, pathlib, sys
domain, pipe_priority, regex_priority = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
expected = {'sentinel': ('/api', '10')}
if pipe_priority != 'absent': expected['pipe'] = ('/api|assets', pipe_priority)
if regex_priority != 'absent': expected['regex'] = ('/(api|assets)', regex_priority)
for part in ['config', 'runtime/applied']:
    with (domain / part / 'paths.csv').open() as stream:
        actual = {row['path_id']: (row['path_prefix'], row['priority']) for row in csv.DictReader(stream)}
    if actual != expected:
        raise SystemExit('[FAIL] Wrong path targeted in %s: expected %r, got %r' % (part, expected, actual))
PY
}

# A real public apply establishes a stopped backend and three distinct paths.
# The /api sentinel detects the old picker truncating /api|assets to /api.
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
  csv_join_row 38080 8080 http '' '' no off '' off auto >>"$DOMAIN/config/ports.csv"
  {
    csv_join_row sentinel 38080 /api prefix 10 '' none ''
    csv_join_row pipe 38080 '/api|assets' prefix 20 '' none ''
    csv_join_row regex 38080 '/(api|assets)' regex 30 '' none ''
  } >>"$DOMAIN/config/paths.csv"
)
run_cli apply-domain-config example.com
assert_paths 20 30

# Direct CLI operands retain their existing interpretation.
run_cli update-path-option example.com 38080 '/(api|assets)' --priority 41
assert_paths 20 41

# Run the collected operands through the public CLI, including normal source
# export/publication. Before the fix this succeeds against the wrong /api row.
collect_path_choice update-path-option 2 >"$TEST_WORK/prompt-output" || fail_test 'Update picker failed'
run_cli "$SELECTED_CMD" "${SELECTED_ARGS[@]}" --priority 42
assert_paths 42 41
[ "${PATH_CHOICE_LABELS[2]}" = '/api|assets' ] || fail_test 'Update picker displayed a truncated label'

collect_path_choice set-nginx-directive 2 >"$TEST_WORK/prompt-output" || fail_test 'Directive picker failed'
run_cli "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
python3 - "$DOMAIN" <<'PY'
import csv, pathlib, sys
domain = pathlib.Path(sys.argv[1])
for part in ['config', 'runtime/applied']:
    with (domain / part / 'nginx_directives.csv').open() as stream:
        rows = list(csv.DictReader(stream))
    assert len(rows) == 1 and rows[0]['path_prefix'] == '/api|assets', rows
    assert rows[0]['directive_name'] == 'proxy_read_timeout' and rows[0]['directive_value'] == '9s', rows
PY

# Remove the explicit directive before its owning path so this regression
# exercises selection rather than the separate path/directive cleanup policy.
collect_path_choice remove-nginx-directive 2 >"$TEST_WORK/prompt-output" || fail_test 'Directive removal picker failed'
run_cli "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
python3 - "$DOMAIN" <<'PY'
import csv, pathlib, sys
domain = pathlib.Path(sys.argv[1])
for part in ['config', 'runtime/applied']:
    with (domain / part / 'nginx_directives.csv').open() as stream:
        assert list(csv.DictReader(stream)) == [], 'Directive removal did not publish to ' + part
PY

collect_path_choice remove-path-option 2 >"$TEST_WORK/prompt-output" || fail_test 'Remove picker failed'
run_cli "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
assert_paths absent 41
run_cli remove-path-option example.com 38080 '/(api|assets)'
assert_paths absent absent
TEST_COMPLETE=true
printf '[PASS] picker and CLI path mutations preserve the intended target and /api sentinel\n'
