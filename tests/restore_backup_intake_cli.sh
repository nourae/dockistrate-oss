#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-restore-intake-cli.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
CHECKOUT="$TEST_DIR/checkout"
mkdir -p "$CHECKOUT" "$TEST_DIR/bin" "$TEST_DIR/source/payload"
cp "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$CHECKOUT/"
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$CHECKOUT/"
export INTAKE_TAR_TRACE="$TEST_DIR/tar.trace"
export INTAKE_GZIP_TRACE="$TEST_DIR/gzip.trace"
export TEST_REAL_TAR
export TEST_REAL_GZIP
TEST_REAL_TAR="$(command -v tar)"
TEST_REAL_GZIP="$(command -v gzip)"
cat >"$TEST_DIR/bin/tar" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INTAKE_TAR_TRACE"
exec "$TEST_REAL_TAR" "$@"
SHIM
cat >"$TEST_DIR/bin/gzip" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INTAKE_GZIP_TRACE"
exec "$TEST_REAL_GZIP" "$@"
SHIM
cat >"$TEST_DIR/bin/docker" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod 700 "$TEST_DIR/bin/tar" "$TEST_DIR/bin/gzip" "$TEST_DIR/bin/docker"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$TEST_DIR/output" ] || cat "$TEST_DIR/output" >&2
  exit 1
}

function run_cli() {
  PATH="$TEST_DIR/bin:$PATH" SKIP_DOCKER_CHECKS=true \
    "$BASH" "$CHECKOUT/dockistrate.sh" "$@" >"$TEST_DIR/output" 2>&1
}

function assert_no_workspace() {
  local found=""
  found="$(find "$CHECKOUT/state/tmp" -mindepth 1 -maxdepth 1 -name 'restore_*' -print)"
  [ -z "$found" ] || fail_test 'restore left an intake workspace behind'
}

function assert_current_config() {
  [ "$(cat "$CHECKOUT/state/config/intake-canary.csv")" = current ] || fail_test 'rejected restore changed current config'
  cmp -s "$CHECKOUT/state/config/global_settings.csv" "$TEST_DIR/current-settings" || fail_test 'rejected restore changed settings'
  assert_no_workspace
}

run_cli set-acl-policy allow || fail_test 'could not initialize disposable CLI state'
# A harmless saved secret marker verifies delayed verbose startup respects
# redacted visibility, including subsequent settings loads and rendering.
# shellcheck source=helpers/global_csv.sh
source "$ROOT_DIR/tests/helpers/global_csv.sh"
(
  ROOT_DIR="$CHECKOUT"
  test_global_csv_set "$CHECKOUT/state/config/global_settings.csv" VISIBILITY_POLICY redacted
  test_global_csv_set "$CHECKOUT/state/config/global_settings.csv" NGINX_DOCKER_OPTS '--env INTAKE_TOKEN=restore-intake-secret-marker'
)
[ "$(test_global_csv_get "$CHECKOUT/state/config/global_settings.csv" NGINX_DOCKER_OPTS)" = '--env INTAKE_TOKEN=restore-intake-secret-marker' ] || fail_test 'could not seed redacted saved option'
printf 'archived\n' >"$CHECKOUT/state/config/intake-canary.csv"
cp -R "$CHECKOUT/state/config" "$TEST_DIR/source/payload/config"
# A current archive includes its domain/shared payload even for an empty host.
mkdir -p "$TEST_DIR/source/payload/domains" "$TEST_DIR/source/payload/shared"
printf '%s\n' 'format_version,state_schema_version' '5,5' >"$TEST_DIR/source/payload/backup_manifest.csv"
ARCHIVE="$TEST_DIR/backup.tar.gz"
(cd "$TEST_DIR/source" && COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
  "$TEST_REAL_TAR" -czf "$ARCHIVE" payload)
printf 'current\n' >"$CHECKOUT/state/config/intake-canary.csv"
cp "$CHECKOUT/state/config/global_settings.csv" "$TEST_DIR/current-settings"

# The real dispatcher propagates a bounded-intake failure without changing live
# configuration. Noninteractive restores keep their established auto-approval.
export RESTORE_MAX_ARCHIVE_BYTES=1
if run_cli restore-backup "$ARCHIVE"; then fail_test 'CLI accepted an archive above its configured bound'; fi
grep -Fq RESTORE_MAX_ARCHIVE_BYTES "$TEST_DIR/output" || fail_test 'CLI omitted actionable archive-limit diagnostic'
assert_current_config

export RESTORE_MAX_ARCHIVE_BYTES=1048576
export RESTORE_MAX_EXPANDED_BYTES=1048576
export RESTORE_MAX_ENTRIES=1000
run_cli -v restore-backup "$ARCHIVE" || fail_test 'CLI did not accept explicit larger bounds'
[ "$(cat "$CHECKOUT/state/config/intake-canary.csv")" = archived ] || fail_test 'successful CLI restore did not restore archived data'
[ -s "$CHECKOUT/state/logs/docker_manager.log" ] || fail_test 'delayed verbose restore did not initialize logging'
if grep -Fq restore-intake-secret-marker "$TEST_DIR/output" "$CHECKOUT/state/logs/docker_manager.log"; then
  fail_test 'delayed verbose restore leaked redacted settings'
fi
assert_no_workspace

printf 'current\n' >"$CHECKOUT/state/config/intake-canary.csv"
cp "$CHECKOUT/state/config/global_settings.csv" "$TEST_DIR/current-settings"
export RESTORE_MAX_EXPANDED_BYTES=1
if run_cli restore-backup "$TEST_DIR/source/payload"; then fail_test 'CLI accepted an oversized directory backup'; fi
grep -Fq RESTORE_MAX_EXPANDED_BYTES "$TEST_DIR/output" || fail_test 'CLI omitted actionable directory-limit diagnostic'
assert_current_config
export RESTORE_MAX_EXPANDED_BYTES=1048576

# Empty only this fixture's backup choices so the existing missing-setup menu
# offers its manual-path flow. Menu positions come from the real menu data.
rm -rf "$CHECKOUT/state/backups"
mkdir -p "$CHECKOUT/state/backups"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
advanced_choice='' category_choice='' restore_choice=''
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_HOME_OPTIONS[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_HOME_OPTIONS[$idx]}" != "$INTERACTIVE_PICKER_HOME_ADVANCED_LABEL" ] || advanced_choice=$((idx + 1))
done
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_CATEGORIES[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_CATEGORIES[$idx]}" != 'Backups & Restore' ] || category_choice=$((idx + 2))
done
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_COMMANDS_BACKUPS_RESTORE[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_COMMANDS_BACKUPS_RESTORE[$idx]}" != restore-backup ] || restore_choice=$((idx + 1))
done
for choice in "$advanced_choice" "$category_choice" "$restore_choice"; do
  [ -n "$choice" ] || fail_test 'required restore picker entry is missing'
done

function run_picker_cancel() {
  : >"$INTAKE_TAR_TRACE"
  : >"$INTAKE_GZIP_TRACE"
  printf '%s\n%s\n%s\n2\n%s\n\n1\nn\n\nq\n' \
    "$advanced_choice" "$category_choice" "$restore_choice" "$1" |
    PATH="$TEST_DIR/bin:$PATH" SKIP_DOCKER_CHECKS=true \
      "$BASH" "$CHECKOUT/dockistrate.sh" -i >"$TEST_DIR/output" 2>&1 || fail_test 'interactive restore cancellation failed'
  grep -Fq '[Info] Restore canceled.' "$TEST_DIR/output" || fail_test 'picker did not reach restore confirmation'
  [ ! -s "$INTAKE_TAR_TRACE" ] || fail_test 'interactive cancellation invoked tar before confirmation'
  [ ! -s "$INTAKE_GZIP_TRACE" ] || fail_test 'interactive cancellation expanded gzip data before confirmation'
  assert_current_config
}

run_picker_cancel "$ARCHIVE"
run_picker_cancel "$TEST_DIR/source/payload"

# A restore that is canceled or rejected must not trigger startup migration.
# Empty settings and an older schema are deliberately repairable startup state.
: >"$CHECKOUT/state/config/global_settings.csv"
printf '0\n' >"$CHECKOUT/state/config/state_schema_version"
cp "$CHECKOUT/state/config/global_settings.csv" "$TEST_DIR/current-settings"
run_picker_cancel "$ARCHIVE"
[ "$(cat "$CHECKOUT/state/config/state_schema_version")" = 0 ] || fail_test 'cancellation migrated the state schema'
export RESTORE_MAX_ARCHIVE_BYTES=1
if run_cli restore-backup "$ARCHIVE"; then fail_test 'oversized restore accepted with uninitialized settings'; fi
assert_current_config
[ "$(cat "$CHECKOUT/state/config/state_schema_version")" = 0 ] || fail_test 'rejected intake migrated the state schema'

# A fresh checkout can reject input before creating a live configuration.
rm -rf "$CHECKOUT/state"
if run_cli restore-backup "$ARCHIVE"; then fail_test 'fresh checkout accepted oversized archive'; fi
[ ! -e "$CHECKOUT/state/config" ] || fail_test 'rejected intake initialized live configuration'
assert_no_workspace

# The no-backups suggestion must prepare the replacement command's runtime.
unset RESTORE_MAX_ARCHIVE_BYTES
printf '%s\n%s\n%s\n1\nintake-handoff\n1\n\nq\n' \
  "$advanced_choice" "$category_choice" "$restore_choice" |
  PATH="$TEST_DIR/bin:$PATH" SKIP_DOCKER_CHECKS=true \
    "$BASH" "$CHECKOUT/dockistrate.sh" -i >"$TEST_DIR/output" 2>&1 || fail_test 'restore-to-create picker handoff failed'
find "$CHECKOUT/state/backups" -name '*intake-handoff*' -print | grep -q . || fail_test 'missing-setup guidance did not create a backup'

printf '[tests] restore_backup_intake_cli.sh: PASS\n'
