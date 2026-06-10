#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/state_sandbox.sh
source "$ROOT_DIR/tests/lib/state_sandbox.sh"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/cli/upgrade_preflight.sh
source "$ROOT_DIR/lib/cli/upgrade_preflight.sh"

TMP_DIR=""
TEMP_TAGS=""

function cleanup() {
  local tag
  for tag in $TEMP_TAGS; do
    git tag -d "$tag" >/dev/null 2>&1 || true
  done
  if [ -n "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER:-false}" != "true" ]; then
    dockistrate_test_state_sandbox_restore
  fi
}
trap cleanup EXIT

if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER:-false}" != "true" ]; then
  dockistrate_test_state_sandbox "$ROOT_DIR"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-update-schema.XXXXXX")"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function reset_state() {
  rm -rf "$ROOT_DIR/state"
  mkdir -p "$ROOT_DIR/state/config" "$ROOT_DIR/state/backups" "$ROOT_DIR/state/logs"
}

function run_preflight_status() {
  set +e
  ./dockistrate.sh upgrade-preflight "$@" >"$TMP_DIR/preflight.out" 2>"$TMP_DIR/preflight.err"
  local status=$?
  set -e
  return "$status"
}

function expect_status() {
  local expected="$1"
  shift
  if run_preflight_status "$@"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq "$expected" ] || {
    echo "[Error] Expected status ${expected} for upgrade-preflight $*, got ${status}" >&2
    echo "[stdout]" >&2
    cat "$TMP_DIR/preflight.out" >&2
    echo "[stderr]" >&2
    cat "$TMP_DIR/preflight.err" >&2
    exit 1
  }
}

function create_temp_tag_with_version() {
  local tag="$1" version="$2" tmp_index="" blob="" tree="" commit=""

  tmp_index="$TMP_DIR/index.${tag}"
  (
    export GIT_INDEX_FILE="$tmp_index"
    git read-tree HEAD
    blob="$(printf '%s\n' "$version" | git hash-object -w --stdin)"
    git update-index --cacheinfo 100644 "$blob" VERSION
    tree="$(git write-tree)"
    commit="$(
      printf 'test target %s\n' "$tag" |
        GIT_AUTHOR_NAME="Dockistrate Test" \
          GIT_AUTHOR_EMAIL="dockistrate-test@example.invalid" \
          GIT_COMMITTER_NAME="Dockistrate Test" \
          GIT_COMMITTER_EMAIL="dockistrate-test@example.invalid" \
          git commit-tree "$tree" -p HEAD
    )"
    git tag "$tag" "$commit"
  )
  TEMP_TAGS="${TEMP_TAGS} ${tag}"
}

function write_tar_listing_stub() {
  local stub_dir="${1:-}"

  mkdir -p "$stub_dir"
  cat >"$stub_dir/tar" <<'EOF_TAR'
#!/usr/bin/env bash
set -Eeuo pipefail

case " $* " in
*" -tzf "*) ;;
*) exit 1 ;;
esac

root="${TAR_STUB_ROOT:-backup}"
case "${TAR_STUB_MODE:-valid}" in
valid)
  printf '%s\n' "$root/" "$root/config/" "$root/config/marker.txt"
  ;;
too_many)
  printf '%s\n' "$root/" "$root/config/" "$root/config/marker.txt"
  i=1
  while [ "$i" -le 6 ]; do
    printf '%s\n' "$root/file-$i"
    i=$((i + 1))
  done
  ;;
too_long)
  printf '%s\n' "$root/" "$root/config/" "$root/config/marker.txt"
  entry="$root/"
  while [ "${#entry}" -le 30 ]; do
    entry="${entry}x"
  done
  printf '%s\n' "$entry"
  ;;
*)
  exit 1
  ;;
esac
EOF_TAR
  chmod +x "$stub_dir/tar"
}

function run_archive_listing_stub() {
  local mode="${1:-}" root="${2:-}" max_entries="${3:-20}" max_entry_length="${4:-100}"
  local archive="$TMP_DIR/stub-archive.tar.gz" stub_dir="$TMP_DIR/tar-stub"

  printf 'stub\n' >"$archive"
  write_tar_listing_stub "$stub_dir"

  (
    export TAR_STUB_MODE="$mode"
    export TAR_STUB_ROOT="$root"
    UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRIES="$max_entries"
    UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRY_LENGTH="$max_entry_length"
    PATH="$stub_dir:$PATH"
    upgrade_preflight_backup_archive_is_full "$archive" "${root}.tar.gz"
  )
}

reset_state
rm -f "$ROOT_DIR/state/config/state_schema_version"
expect_status 0

reset_state
printf '%s\n' "1" >"$ROOT_DIR/state/config/state_schema_version"
expect_status 0

reset_state
printf '%s\n' "malformed" >"$ROOT_DIR/state/config/state_schema_version"
expect_status 4

reset_state
printf '%s\n' "2" >"$ROOT_DIR/state/config/state_schema_version"
expect_status 4

reset_state
expect_status 5 --require-backup

reset_state
printf '%s\n' "ignore" >"$ROOT_DIR/state/backups/.hidden"
printf '%s\n' "ignore" >"$ROOT_DIR/state/backups/archive.tar.gz.partial"
printf '%s\n' "ignore" >"$ROOT_DIR/state/backups/20260531_000000_pre_save_config.tar.gz"
printf '%s\n' "ignore" >"$ROOT_DIR/state/backups/20260531_000001_post_save_config.tar.gz"
printf '%s\n' "ignore" >"$ROOT_DIR/state/backups/20260531_000002_ManualBackup.tar.gz"
mkdir -p "$ROOT_DIR/state/backups/20260531_000004_Unrelated"
mkdir -p "$TMP_DIR/symlink_backup/20260531_000005_Symlink/config"
ln -s "$TMP_DIR/symlink_backup/20260531_000005_Symlink" "$ROOT_DIR/state/backups/20260531_000005_Symlink"
mkdir -p "$TMP_DIR/symlink_archive/20260531_000006_SymlinkArchive/config"
printf '%s\n' "state" >"$TMP_DIR/symlink_archive/20260531_000006_SymlinkArchive/config/marker.txt"
(cd "$TMP_DIR/symlink_archive" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$TMP_DIR/20260531_000006_SymlinkArchive.tar.gz" "20260531_000006_SymlinkArchive")
ln -s "$TMP_DIR/20260531_000006_SymlinkArchive.tar.gz" "$ROOT_DIR/state/backups/20260531_000006_SymlinkArchive.tar.gz"
mkdir -p "$TMP_DIR/extra_top/20260531_000007_ExtraTop/config" "$TMP_DIR/extra_top/extra"
printf '%s\n' "state" >"$TMP_DIR/extra_top/20260531_000007_ExtraTop/config/marker.txt"
printf '%s\n' "extra" >"$TMP_DIR/extra_top/extra/file.txt"
(cd "$TMP_DIR/extra_top" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$ROOT_DIR/state/backups/20260531_000007_ExtraTop.tar.gz" "20260531_000007_ExtraTop" "extra")
: >"$ROOT_DIR/state/backups/empty.tar.gz"
expect_status 5 --require-backup

reset_state
mkdir -p "$ROOT_DIR/state/backups/20260531_000000_Test/config"
expect_status 0 --require-backup

reset_state
mkdir -p "$TMP_DIR/full_backup/20260531_000003_ManualBackup/config"
printf '%s\n' "state" >"$TMP_DIR/full_backup/20260531_000003_ManualBackup/config/marker.txt"
(cd "$TMP_DIR/full_backup" && LC_ALL=C COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "$ROOT_DIR/state/backups/20260531_000003_ManualBackup.tar.gz" "20260531_000003_ManualBackup")
expect_status 0 --require-backup

archive_root="20260531_000008_Limited"
run_archive_listing_stub valid "$archive_root" 20 100 ||
  fail_test "bounded archive listing should accept a valid full backup archive"
if run_archive_listing_stub too_many "$archive_root" 3 100; then
  fail_test "bounded archive listing should reject archives with too many entries"
fi
if run_archive_listing_stub too_long "$archive_root" 20 20; then
  fail_test "bounded archive listing should reject archives with overlong entries"
fi

valid_tag="v999.$$.1"
create_temp_tag_with_version "$valid_tag" "${valid_tag#v}"
reset_state
expect_status 0 "$valid_tag"

mismatched_tag="v999.$$.2"
create_temp_tag_with_version "$mismatched_tag" "999.$$.3"
reset_state
expect_status 3 "$mismatched_tag"
grep -Fq "Target tag ${mismatched_tag} points to VERSION 999.$$.3; expected ${mismatched_tag#v}." "$TMP_DIR/preflight.err" ||
  fail_test "tag/VERSION mismatch should fail clearly"

reset_state
expect_status 3 "v999.$$.99"
grep -Fq "git fetch --tags --prune origin" "$TMP_DIR/preflight.err" ||
  fail_test "unknown tag should include explicit fetch guidance"

expect_status 2 "v01.2.3"
expect_status 2 "v1.2.3-rc.1"

if ! upgrade_preflight_compare_schema 1 1; then
  fail_test "equal schema comparison should pass"
fi
if ! upgrade_preflight_compare_schema 1 2; then
  fail_test "newer target schema comparison should pass"
fi
set +e
upgrade_preflight_compare_schema 2 1 >"$TMP_DIR/compare.out" 2>"$TMP_DIR/compare.err"
status=$?
set -e
[ "$status" -eq 4 ] || fail_test "lower target schema should return 4"
grep -Fq "cannot downgrade state from 2 to 1" "$TMP_DIR/compare.err" ||
  fail_test "lower target schema should use stable downgrade message"

MOCK_VERSION_CONTENT=""
MOCK_VERSION_STATUS=0
MOCK_SCHEMA_VERSION_CONTENT=""
MOCK_SCHEMA_VERSION_STATUS=1
MOCK_COMMON_CONTENT=""
MOCK_COMMON_STATUS=1

function upgrade_preflight_git_show_file() {
  case "${2:-}" in
  VERSION)
    [ "$MOCK_VERSION_STATUS" -eq 0 ] || return 1
    printf '%s\n' "$MOCK_VERSION_CONTENT"
    ;;
  lib/config/schema_version.sh)
    [ "$MOCK_SCHEMA_VERSION_STATUS" -eq 0 ] || return 1
    printf '%s\n' "$MOCK_SCHEMA_VERSION_CONTENT"
    ;;
  lib/config/common.sh)
    [ "$MOCK_COMMON_STATUS" -eq 0 ] || return 1
    printf '%s\n' "$MOCK_COMMON_CONTENT"
    ;;
  *)
    return 1
    ;;
  esac
}

MOCK_VERSION_CONTENT="1.2.3"
[ "$(upgrade_preflight_read_target_version "v1.2.3")" = "1.2.3" ] ||
  fail_test "target VERSION should parse stable semver"

MOCK_VERSION_STATUS=1
set +e
upgrade_preflight_read_target_version "v1.2.3" >/dev/null 2>"$TMP_DIR/version_missing.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail_test "missing target VERSION should fail"

MOCK_VERSION_STATUS=0
MOCK_VERSION_CONTENT="1.2.3-rc.1"
set +e
upgrade_preflight_read_target_version "v1.2.3" >/dev/null 2>"$TMP_DIR/version_bad.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail_test "unparseable target VERSION should fail"

MOCK_SCHEMA_VERSION_STATUS=0
MOCK_SCHEMA_VERSION_CONTENT='CURRENT_STATE_SCHEMA_VERSION="3"'
[ "$(upgrade_preflight_read_target_schema "v1.2.3")" = "3" ] ||
  fail_test "schema_version.sh should be preferred"

MOCK_SCHEMA_VERSION_STATUS=1
MOCK_COMMON_STATUS=0
MOCK_COMMON_CONTENT='CURRENT_STATE_SCHEMA_VERSION="2"'
[ "$(upgrade_preflight_read_target_schema "v1.2.3")" = "2" ] ||
  fail_test "legacy common.sh fallback should parse exact assignment"

MOCK_COMMON_CONTENT='# no schema marker in this historical tag'
[ "$(upgrade_preflight_read_target_schema "v1.2.3")" = "1" ] ||
  fail_test "tag predating schema constants should be treated as schema 1"

MOCK_COMMON_STATUS=1
set +e
upgrade_preflight_read_target_schema "v1.2.3" >/dev/null 2>"$TMP_DIR/schema_missing.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail_test "missing target schema metadata should fail"
MOCK_COMMON_STATUS=0

MOCK_COMMON_CONTENT='CURRENT_STATE_SCHEMA_VERSION="2" # comment'
set +e
upgrade_preflight_read_target_schema "v1.2.3" >/dev/null 2>"$TMP_DIR/schema_comment.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail_test "legacy schema assignment with trailing comment should fail"

MOCK_COMMON_CONTENT=$'CURRENT_STATE_SCHEMA_VERSION="2"\nCURRENT_STATE_SCHEMA_VERSION="3"'
set +e
upgrade_preflight_read_target_schema "v1.2.3" >/dev/null 2>"$TMP_DIR/schema_multiple.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail_test "multiple legacy schema assignments should fail"

MOCK_SCHEMA_VERSION_STATUS=0
MOCK_SCHEMA_VERSION_CONTENT='CURRENT_STATE_SCHEMA_VERSION=2'
MOCK_COMMON_STATUS=1
set +e
upgrade_preflight_read_target_schema "v1.2.3" >/dev/null 2>"$TMP_DIR/schema_unquoted.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail_test "unquoted target schema should fail"

MOCK_SCHEMA_VERSION_CONTENT='CURRENT_STATE_SCHEMA_VERSION="0"'
set +e
upgrade_preflight_read_target_schema "v1.2.3" >/dev/null 2>"$TMP_DIR/schema_zero.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail_test "zero target schema should fail"

echo "[tests] update_preflight_schema_tags.sh: PASS"
